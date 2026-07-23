import SwiftUI
import UIKit

private enum WorkoutStartAvailabilityAlert: String, Identifiable {
    case unsupported
    case activationFailed
    case noPairedWatch
    case companionAppNotInstalled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unsupported, .noPairedWatch:
            return "Apple Watch Required"
        case .activationFailed:
            return "Unable to Check Apple Watch"
        case .companionAppNotInstalled:
            return "Install BikeComputer on Apple Watch"
        }
    }

    var message: String {
        switch self {
        case .unsupported:
            return "Starting a workout from iPhone requires iOS 17 or later and the BikeComputer app on Apple Watch."
        case .activationFailed:
            return "BikeComputer couldn’t check your Apple Watch. Make sure Bluetooth and Wi-Fi are on, then try again."
        case .noPairedWatch:
            return "You need the BikeComputer app on an Apple Watch to start tracking your workout. Pair an Apple Watch with this iPhone first."
        case .companionAppNotInstalled:
            return "Open the Watch app on this iPhone, tap My Watch, then install BikeComputer under Available Apps."
        }
    }
}

struct WorkoutStartButton<Label: View>: View {
    @ObservedObject var watchAvailability: WorkoutWatchAvailabilityMonitor
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var pendingStart = false
    @State private var presentedAlert: WorkoutStartAvailabilityAlert?

    var body: some View {
        Button {
            requestStart()
        } label: {
            label()
        }
        .alert(item: $presentedAlert) { alert in
            availabilityAlert(alert)
        }
        .onChange(of: watchAvailability.availability) { availability in
            guard pendingStart else { return }
            handle(availability)
        }
    }

    private func requestStart() {
        handle(watchAvailability.availability)
    }

    private func handle(_ availability: WorkoutWatchAvailabilityV1) {
        switch availability {
        case .activating:
            pendingStart = true
            watchAvailability.activate()
        case .ready:
            pendingStart = false
            action()
        case .unsupported:
            pendingStart = false
            presentedAlert = .unsupported
        case .activationFailed:
            pendingStart = false
            presentedAlert = .activationFailed
        case .noPairedWatch:
            pendingStart = false
            presentedAlert = .noPairedWatch
        case .companionAppNotInstalled:
            pendingStart = false
            presentedAlert = .companionAppNotInstalled
        }
    }

    private func availabilityAlert(
        _ alert: WorkoutStartAvailabilityAlert
    ) -> Alert {
        if alert == .activationFailed {
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text("Try Again")) {
                    pendingStart = true
                    watchAvailability.activate()
                },
                secondaryButton: .cancel()
            )
        }
        return Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            dismissButton: .default(Text("OK"))
        )
    }
}

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

struct WorkoutFinishButton<Label: View>: View {
    @ObservedObject var store: WorkoutMetricsStore
    let onEndAndSave: () -> Void
    let onDiscard: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var finishPrompt: WorkoutFinishPrompt?

    var body: some View {
        Button(role: .destructive) {
            if let sessionID = store.presentation.sessionID {
                finishPrompt = .options(sessionID: sessionID)
            }
        } label: {
            label()
        }
        .confirmationDialog(
            "Finish this ride?",
            isPresented: finishOptionsPresented
        ) {
            if case .options(let sessionID) = finishPrompt {
                Button("End and Save") {
                    finishPrompt = nil
                    guard store.presentation.sessionID == sessionID else { return }
                    onEndAndSave()
                }
                Button("Discard Workout", role: .destructive) {
                    requestDiscardConfirmation(for: sessionID)
                }
                Button("Keep Riding", role: .cancel) {
                    finishPrompt = nil
                }
            }
        } message: {
            Text("Apple Watch performs the save. If it is unreachable, the workout continues there.")
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
                        currentSessionID: store.presentation.sessionID,
                        discard: onDiscard
                    )
                }
                Button(
                    WorkoutDiscardDisclosureV1.confirmTitle,
                    role: .destructive
                ) {
                    WorkoutDiscardDisclosureV1.perform(
                        .confirmDiscard,
                        expectedSessionID: sessionID,
                        currentSessionID: store.presentation.sessionID,
                        discard: onDiscard
                    )
                }
            }
        } message: {
            Text(WorkoutDiscardDisclosureV1.message)
        }
        .onChange(of: store.presentation.sessionID) { _ in
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
            guard store.presentation.sessionID == sessionID else { return }
            finishPrompt = .discardConfirmation(sessionID: sessionID)
        }
    }
}

struct WorkoutCompactCard: View {
    @ObservedObject var store: WorkoutMetricsStore
    @ObservedObject var watchAvailability: WorkoutWatchAvailabilityMonitor
    let onStart: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: stateIcon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(stateColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(stateColor.opacity(0.25), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 5, x: 0, y: 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var action: some View {
        switch store.presentation.connectionState {
        case .idle:
            WorkoutStartButton(
                watchAvailability: watchAvailability,
                action: onStart
            ) {
                Text("Start")
            }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Start outdoor cycling workout on Apple Watch")
        case .launchingWatch, .awaitingFirstSnapshot:
            ProgressView()
                .accessibilityLabel("Starting workout on Apple Watch")
        case .unsupported:
            EmptyView()
        case .failed:
            Button("Details", action: onOpen)
                .buttonStyle(.bordered)
        case .connected, .stale, .disconnected, .ended:
            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open workout dashboard")
        }
    }

    private var title: String {
        let presentation = store.presentation
        switch presentation.connectionState {
        case .unsupported:
            return "Workout companion unavailable"
        case .idle:
            return "Outdoor cycle"
        case .launchingWatch:
            return "Starting on Apple Watch"
        case .awaitingFirstSnapshot:
            return "Connecting to Apple Watch"
        case .connected:
            return stateLabel(presentation.sessionState)
        case .stale:
            return "Workout data delayed"
        case .disconnected:
            return "Apple Watch disconnected"
        case .ended:
            return terminalTitle(presentation.finalSnapshot ?? presentation.snapshot)
        case .failed:
            return errorTitle(presentation.errorCode)
        }
    }

    private var detail: String {
        let presentation = store.presentation
        switch presentation.connectionState {
        case .unsupported:
            return "Requires iOS 17 and watchOS 10"
        case .idle:
            return "Recorded and saved by Apple Watch"
        case .launchingWatch:
            return "Keep your Watch unlocked"
        case .awaitingFirstSnapshot:
            return "Waiting for live metrics"
        case .failed:
            return errorDetail(
                presentation.errorCode,
                context: WorkoutErrorCopyV1.context(for: presentation)
            )
        case .ended:
            return summaryDetail(presentation.finalSnapshot ?? presentation.snapshot)
        case .disconnected:
            if !presentation.isWorkoutActive {
                return errorDetail(
                    presentation.errorCode ?? .watchUnavailable,
                    context: WorkoutErrorCopyV1.context(for: presentation)
                )
            }
            fallthrough
        case .connected, .stale:
            if let errorCode = presentation.errorCode {
                return errorDetail(
                    errorCode,
                    context: WorkoutErrorCopyV1.context(for: presentation)
                )
            }
            return liveDetail(presentation.snapshot)
        }
    }

    private var stateIcon: String {
        switch store.presentation.connectionState {
        case .idle: return "figure.outdoor.cycle"
        case .launchingWatch, .awaitingFirstSnapshot: return "applewatch.radiowaves.left.and.right"
        case .connected: return "heart.fill"
        case .stale: return "clock.badge.exclamationmark"
        case .disconnected: return "applewatch.slash"
        case .ended: return "checkmark.circle.fill"
        case .failed, .unsupported: return "exclamationmark.triangle.fill"
        }
    }

    private var stateColor: Color {
        switch store.presentation.connectionState {
        case .connected: return .green
        case .stale, .launchingWatch, .awaitingFirstSnapshot: return .orange
        case .failed, .disconnected, .unsupported: return .red
        case .ended: return .blue
        case .idle: return .accentColor
        }
    }

    private func liveDetail(_ snapshot: WorkoutSnapshotV1) -> String {
        let elapsed = WorkoutValueFormatter.duration(snapshot.elapsedTime?.value)
        let heart = WorkoutValueFormatter.heartRate(snapshot.currentHeartRate?.value)
        let speed = WorkoutValueFormatter.speed(snapshot.currentSpeed?.value)
        return "\(elapsed)  •  \(heart) BPM  •  \(speed) KM/H"
    }

    private func summaryDetail(_ snapshot: WorkoutSnapshotV1) -> String {
        let elapsed = WorkoutValueFormatter.duration(snapshot.elapsedTime?.value)
        let distance = WorkoutValueFormatter.distance(snapshot.cyclingDistance?.value)
        let unit = WorkoutValueFormatter.distanceUnit(snapshot.cyclingDistance?.value)
        let prefix: String
        switch snapshot.terminalOutcome {
        case .saved:
            prefix = "Saved by Apple Watch"
        case .discarded:
            prefix = "Not saved to Health"
        case nil:
            prefix = "Finished on Apple Watch"
        }
        return "\(prefix)  •  \(elapsed)  •  \(distance) \(unit)"
    }
}

struct WorkoutDashboardView: View {
    @ObservedObject var store: WorkoutMetricsStore
    @ObservedObject var watchAvailability: WorkoutWatchAvailabilityMonitor
    let onStart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onMarkSegment: () -> Void
    let onEndAndSave: () -> Void
    let onDiscard: () -> Void
    let onDone: () -> Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var segmentToast: WorkoutCompletedSegmentV1?
    @State private var observedSegmentIndex: UInt32?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    connectionBanner

                    if store.presentation.connectionState == .idle {
                        idleContent
                    } else if store.presentation.connectionState == .unsupported {
                        unavailableContent
                    } else {
                        liveOrSummaryContent
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .overlay(alignment: .top) {
            if let segmentToast {
                segmentToastView(segmentToast)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .onAppear {
            observedSegmentIndex = currentCompletedSegment?.index
        }
        .onChange(of: currentCompletedSegment?.index) { index in
            let previousIndex = observedSegmentIndex
            observedSegmentIndex = index
            guard scenePhase == .active,
                  let index,
                  index != previousIndex,
                  store.presentation.isWorkoutActive,
                  let segment = currentCompletedSegment else { return }
            UINotificationFeedbackGenerator()
                .notificationOccurred(.success)
            withAnimation {
                segmentToast = segment
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

    private var currentCompletedSegment: WorkoutCompletedSegmentV1? {
        (store.presentation.finalSnapshot ?? store.presentation.snapshot)
            .lastCompletedSegment
    }

    @ViewBuilder
    private var connectionBanner: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { context in
            HStack(spacing: 10) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectionLabel)
                        .font(.subheadline.weight(.semibold))
                    if let age = store.presentation.captureAge(at: context.date) {
                        Text(captureAgeLabel(age))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private var idleContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "figure.outdoor.cycle")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Start an outdoor cycling workout on Apple Watch. Your Watch remains the workout owner and the only device that saves to Health.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            WorkoutStartButton(
                watchAvailability: watchAvailability,
                action: onStart
            ) {
                Text("Start on Apple Watch")
            }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 24)
    }

    private var unavailableContent: some View {
        VStack(spacing: 12) {
            Image(systemName: "applewatch.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Workout mirroring requires iOS 17 or later and watchOS 10 or later.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }

    private var liveOrSummaryContent: some View {
        let snapshot = store.presentation.finalSnapshot
            ?? store.presentation.snapshot
        return VStack(spacing: 16) {
            if store.presentation.connectionState == .failed,
               !store.presentation.isWorkoutActive {
                if let errorCode = store.presentation.errorCode {
                    errorBanner(errorCode)
                }
                controls
            } else {
                if let errorCode = store.presentation.errorCode {
                    errorBanner(errorCode)
                }

                Text(WorkoutValueFormatter.duration(snapshot.elapsedTime?.value))
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .accessibilityLabel("Elapsed time")

                if let segment = snapshot.lastCompletedSegment,
                   store.presentation.isWorkoutActive {
                    Label(
                        "Segment \(segment.index + 1) in progress",
                        systemImage: "flag.checkered"
                    )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: columns, spacing: 12) {
                    metric(
                        "Heart Rate",
                        WorkoutValueFormatter.heartRate(snapshot.currentHeartRate?.value),
                        "BPM",
                        "heart.fill",
                        .red
                    )
                    metric(
                        "Heart Zone",
                        zoneValue(snapshot),
                        "",
                        "waveform.path.ecg",
                        .pink,
                        source: "Configured max HR"
                    )
                    metric(
                        "Speed",
                        WorkoutValueFormatter.speed(snapshot.currentSpeed?.value),
                        "KM/H",
                        "speedometer",
                        .cyan,
                        source: sourceLabel(snapshot.currentSpeed?.source)
                    )
                    metric(
                        "Distance",
                        WorkoutValueFormatter.distance(snapshot.cyclingDistance?.value),
                        WorkoutValueFormatter.distanceUnit(snapshot.cyclingDistance?.value),
                        "point.topleft.down.to.point.bottomright.curvepath",
                        .green
                    )
                    metric(
                        "Energy",
                        WorkoutValueFormatter.energy(snapshot.activeEnergy?.value),
                        "KCAL",
                        "flame.fill",
                        .orange
                    )
                    metric(
                        "Power",
                        WorkoutValueFormatter.whole(snapshot.cyclingPower?.value),
                        "W",
                        "bolt.fill",
                        .yellow
                    )
                    metric(
                        "Cadence",
                        WorkoutValueFormatter.whole(snapshot.cyclingCadence?.value),
                        "RPM",
                        "arrow.triangle.2.circlepath",
                        .mint
                    )
                    metric(
                        "Average HR",
                        WorkoutValueFormatter.heartRate(snapshot.averageHeartRate?.value),
                        "BPM",
                        "heart.text.square",
                        .red.opacity(0.8)
                    )
                    metric(
                        "Altitude",
                        altitudeValue(snapshot.location?.altitude),
                        "M",
                        "mountain.2.fill",
                        .indigo
                    )
                }

                controls

                Text("Workout controls are separate from navigation. Ending either one does not end the other.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        let presentation = store.presentation
        if presentation.connectionState == .ended {
            if presentation.pendingControl == .endAndSave
                || presentation.pendingControl == .discard {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Confirming the finish choice with Apple Watch…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            } else if store.canResetTerminalPresentation {
                Button("Done") {
                    if onDone() {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Waiting for the final saved or discarded result from Apple Watch…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        } else if presentation.connectionState == .failed,
                  !presentation.isWorkoutActive {
            VStack(spacing: 10) {
                if presentation.errorCode == .setupRequired
                    || presentation.errorCode == .authorizationDenied {
                    Text("On Apple Watch, open BikeComputer and tap Set Up Health. If needed, use Watch Settings › Health › Apps › BikeComputer.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                WorkoutStartButton(
                    watchAvailability: watchAvailability,
                    action: onStart
                ) {
                    Text("Try Again")
                }
                    .buttonStyle(.bordered)
            }
        } else if presentation.connectionState == .disconnected,
                  presentation.isWorkoutActive {
            Text("Workout controls return when Apple Watch reconnects. The current workout continues on Watch.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if presentation.connectionState == .disconnected {
            VStack(spacing: 10) {
                Text("No verified workout state was received. Check BikeComputer on Apple Watch; if no ride is active there, try again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                WorkoutStartButton(
                    watchAvailability: watchAvailability,
                    action: onStart
                ) {
                    Text("Try Again")
                }
                    .buttonStyle(.bordered)
            }
        } else if presentation.isWorkoutActive,
                  presentation.sessionID == nil {
            Text("Waiting for the first verified Watch snapshot before workout controls become available.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if presentation.isWorkoutActive {
            if !store.supportsSegmentMarking {
                Text("Update BikeComputer on Apple Watch to mark segments from iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button(action: onMarkSegment) {
                    Label("Segment", systemImage: "flag.checkered")
                }
                .tint(.blue)
                .disabled(
                    presentation.sessionState != .running
                        || presentation.pendingControl != nil
                        || !store.supportsSegmentMarking
                        || store.isSegmentConfirmationPending
                )
                .accessibilityLabel("Mark workout segment")

                if presentation.sessionState == .paused {
                    Button(action: onResume) {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .tint(.green)
                    .disabled(
                        presentation.pendingControl != nil
                            && presentation.pendingControl != .markSegment
                    )
                } else {
                    Button(action: onPause) {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .tint(.orange)
                    .disabled(
                        presentation.sessionState != .running
                            || (presentation.pendingControl != nil
                                && presentation.pendingControl
                                    != .markSegment)
                    )
                }

                WorkoutFinishButton(
                    store: store,
                    onEndAndSave: onEndAndSave,
                    onDiscard: onDiscard
                ) {
                    Label("End", systemImage: "stop.fill")
                }
                .disabled(
                    presentation.sessionState == .ending
                        || (presentation.pendingControl != nil
                            && presentation.pendingControl != .markSegment)
                )
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func segmentToastView(
        _ segment: WorkoutCompletedSegmentV1
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.checkered")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Segment \(segment.index)")
                    .font(.subheadline.weight(.semibold))
                Text(segmentSummary(segment))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
    }

    private func segmentSummary(
        _ segment: WorkoutCompletedSegmentV1
    ) -> String {
        let duration = WorkoutValueFormatter.duration(segment.duration)
        guard let distance = segment.distanceMeters else {
            return duration
        }
        return "\(duration)  •  \(WorkoutValueFormatter.distance(distance)) \(WorkoutValueFormatter.distanceUnit(distance))"
    }

    private func metric(
        _ title: String,
        _ value: String,
        _ unit: String,
        _ icon: String,
        _ color: Color,
        source: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(unit)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let source {
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) \(unit)")
    }

    private func errorBanner(_ code: WorkoutSafeErrorCodeV1) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(
                errorDetail(
                    code,
                    context: WorkoutErrorCopyV1.context(
                        for: store.presentation
                    )
                )
            )
                .font(.subheadline)
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private var columns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var connectionLabel: String {
        switch store.presentation.connectionState {
        case .unsupported: return "Unavailable"
        case .idle: return "Ready"
        case .launchingWatch: return "Starting on Apple Watch"
        case .awaitingFirstSnapshot: return "Waiting for Watch metrics"
        case .connected: return stateLabel(store.presentation.sessionState)
        case .stale: return "Delayed data"
        case .disconnected:
            return store.presentation.isWorkoutActive
                ? "Watch disconnected — workout continues"
                : "Watch disconnected — verify workout on Watch"
        case .ended:
            return terminalTitle(
                store.presentation.finalSnapshot ?? store.presentation.snapshot
            )
        case .failed: return errorTitle(store.presentation.errorCode)
        }
    }

    private var connectionColor: Color {
        switch store.presentation.connectionState {
        case .connected: return .green
        case .launchingWatch, .awaitingFirstSnapshot, .stale: return .orange
        case .disconnected, .failed, .unsupported: return .red
        case .ended: return .blue
        case .idle: return .secondary
        }
    }

    private func captureAgeLabel(_ age: TimeInterval) -> String {
        if age < 1 { return "Captured now" }
        return "Captured \(Int(age.rounded(.down)))s ago"
    }

    private func zoneValue(_ snapshot: WorkoutSnapshotV1) -> String {
        guard let zone = snapshot.currentHeartRateZone else { return "--" }
        return "Zone \(zone)"
    }

    private func altitudeValue(_ altitude: Double?) -> String {
        guard let altitude, altitude.isFinite else { return "--" }
        return String(format: "%.0f", altitude)
    }

    private func sourceLabel(_ source: WorkoutMetricSourceV1?) -> String? {
        switch source {
        case .pairedCyclingSensor: return "Cycling sensor"
        case .watchLocation: return "Watch GPS"
        case .healthKit: return "HealthKit"
        case .watchRoute: return "Watch route"
        case .iPhoneLocation: return "iPhone GPS"
        case .iPhoneNavigation: return "Navigation"
        case .unknown: return "Unknown source"
        case nil: return nil
        }
    }
}

private func stateLabel(_ state: WorkoutSessionStateV1) -> String {
    switch state {
    case .idle: return "Ready"
    case .starting: return "Starting"
    case .running: return "Live workout"
    case .paused: return "Workout paused"
    case .ending: return "Finishing on Apple Watch"
    case .ended: return "Ride finished"
    case .failed: return "Workout failed"
    }
}

private func terminalTitle(_ snapshot: WorkoutSnapshotV1) -> String {
    switch snapshot.terminalOutcome {
    case .saved: return "Workout saved on Apple Watch"
    case .discarded: return "Workout discarded"
    case nil: return "Ride finished on Apple Watch"
    }
}

private func errorTitle(_ code: WorkoutSafeErrorCodeV1?) -> String {
    WorkoutErrorCopyV1.title(code)
}

private func errorDetail(
    _ code: WorkoutSafeErrorCodeV1?,
    context: WorkoutErrorCopyContextV1 = .general
) -> String {
    WorkoutErrorCopyV1.detail(code, context: context)
}
