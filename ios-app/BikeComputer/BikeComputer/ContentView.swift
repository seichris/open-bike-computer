//
//  ContentView.swift
//  BikeComputer
//
//  Main view for the Bike Computer app
//

import SwiftUI
import MapKit
import UIKit

private enum ContentSheetDestination: Identifiable, Equatable {
    case settings
    case bikeComputerSetup
    case sensorSettings
    case workoutDashboard
    case rideMetrics
    case nearbyBicino(peripheralIdentifier: UUID)

    var id: String {
        switch self {
        case .settings: return "settings"
        case .bikeComputerSetup: return "bike-computer-setup"
        case .sensorSettings: return "sensor-settings"
        case .workoutDashboard: return "workout-dashboard"
        case .rideMetrics: return "ride-metrics"
        case .nearbyBicino(let identifier):
            return NearbyBicinoPresentationPolicy.routeID(
                peripheralIdentifier: identifier
            )
        }
    }
}

private struct RideMetricsCompactDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        let preferredHeight: CGFloat =
            context.dynamicTypeSize.isAccessibilitySize ? 360 : 280
        return min(preferredHeight, context.maxDetentValue * 0.72)
    }
}

private extension PresentationDetent {
    static var rideMetricsCompact: PresentationDetent {
        .custom(RideMetricsCompactDetent.self)
    }
}

struct ContentView: View {
    
    // MARK: - State
    
    @StateObject private var coordinator: BikeComputerCoordinator
    @StateObject private var mapViewControlState: MapViewControlState
    @StateObject private var offlineMapManager: OfflineMapManager
    @StateObject private var watchAvailability: WorkoutWatchAvailabilityMonitor
    @ObservedObject private var routeLibrary: PhoneRouteLibrary
    @ObservedObject private var workoutStore: WorkoutMetricsStore
    @ObservedObject private var liveActivityDiagnostics:
        WorkoutLiveActivityDiagnosticStore
    @ObservedObject private var rideDiagnosticsRecorder:
        RideDiagnosticsRecorder
    @ObservedObject private var cyclingSensorStore:
        CyclingSensorStore
    @ObservedObject private var cyclingSensorDetectionCoordinator:
        CyclingSensorDetectionCoordinator
    @ObservedObject private var rideDetectionSettingsStore:
        RideDetectionSettingsStore
    @ObservedObject private var rideAutomationCoordinator:
        RideAutomationCoordinator
    private let workoutMirrorManager: WorkoutMirrorManager
    private let onApplicationActiveChange: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var sourceAddress = ""
    @State private var destinationAddress = ""
    @State private var presentedSheet: ContentSheetDestination?
    @State private var queuedSheetAfterDismiss:
        ContentSheetDestination?
    @State private var activeSheetDestination: ContentSheetDestination?
    @State private var isSheetDismissalInFlight = false
    @State private var rideMetricsDetent = PresentationDetent.rideMetricsCompact
    @State private var workoutSegmentToast: WorkoutCompletedSegmentV1?
    @State private var observedWorkoutSegmentIndex: UInt32?
    @State private var isSearchPanelExpanded = false
    @State private var dismissedOfflineMapOnboarding = false
    @State private var confirmedDeviceMapMissing = false
    @State private var isOfflineMapOnboardingStatePrepared = false
    // Preserve the original key so users who completed the previous first-run
    // flow are not shown a new welcome after updating.
    @AppStorage("offlineMapOnboarding.firstRunCompleted.v1")
    private var hasCompletedFirstRunWelcome = false
    @AppStorage("offlineMapOnboarding.existingInstallMigrationCompleted.v1")
    private var hasMigratedExistingInstallOnboarding = false
    @AppStorage(IPhoneMapAppearance.baseStyleDefaultsKey)
    private var iPhoneMapBaseStyleRawValue =
        IPhoneMapAppearance.defaultValue.baseStyle.rawValue
    @AppStorage(IPhoneMapAppearance.realisticElevationDefaultsKey)
    private var usesRealisticMapElevation =
        IPhoneMapAppearance.defaultValue.usesRealisticElevation
    @State private var offlineMapSelectionWidth: CGFloat?
    @State private var offlineMapSelectionHeight: CGFloat?
    @State private var offlineMapSelectionCenterY: CGFloat?
    @State private var offlineMapSelectionDragStartFrame: CGRect?

    @MainActor
    init(
        workoutMirrorManager: WorkoutMirrorManager,
        cyclingSensorStore: CyclingSensorStore? = nil,
        cyclingSensorDetectionCoordinator:
            CyclingSensorDetectionCoordinator? = nil,
        coordinator: BikeComputerCoordinator? = nil,
        rideDetectionSettingsStore: RideDetectionSettingsStore? = nil,
        rideAutomationCoordinator: RideAutomationCoordinator? = nil,
        watchAvailability: WorkoutWatchAvailabilityMonitor? = nil,
        routeLibrary: PhoneRouteLibrary? = nil,
        liveActivityDiagnostics:
            WorkoutLiveActivityDiagnosticStore? = nil,
        rideDiagnosticsRecorder: RideDiagnosticsRecorder? = nil,
        onApplicationActiveChange:
            @escaping (Bool) -> Void = { _ in }
    ) {
        let liveActivityDiagnostics = liveActivityDiagnostics
            ?? WorkoutLiveActivityDiagnosticStore()
        let rideDiagnosticsRecorder = rideDiagnosticsRecorder
            ?? RideDiagnosticsRecorder()
        let cyclingSensorStore =
            cyclingSensorStore ?? CyclingSensorStore()
        let cyclingSensorDetectionCoordinator =
            cyclingSensorDetectionCoordinator
            ?? CyclingSensorDetectionCoordinator(
                sensorStore: cyclingSensorStore
            )
        let rideDetectionSettingsStore =
            rideDetectionSettingsStore ?? RideDetectionSettingsStore()
        let coordinator = coordinator ?? BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(),
            workoutMetricsStore: workoutMirrorManager.store,
            rideDetectionSettingsStore: rideDetectionSettingsStore
        )
        let watchAvailability = watchAvailability
            ?? WorkoutWatchAvailabilityMonitor(
                heartRateZoneDefaults: .standard,
                rideDetectionSettingsStore: rideDetectionSettingsStore
            )
        let routeLibrary = routeLibrary ?? PhoneRouteLibrary(
            connectivity: PhoneWatchConnectivityCoordinator()
        )
        let rideAutomationCoordinator =
            rideAutomationCoordinator ?? RideAutomationCoordinator(
                bleManager: coordinator.bleManager,
                workoutManager: workoutMirrorManager,
                settingsStore: rideDetectionSettingsStore,
                watchAvailability: watchAvailability
            )
        coordinator.bleManager.onWorkoutStartRequest = {
            Task { @MainActor [weak workoutMirrorManager] in
                workoutMirrorManager?.startOutdoorCyclingOnWatch()
            }
        }
        self.workoutMirrorManager = workoutMirrorManager
        self.onApplicationActiveChange = onApplicationActiveChange
        cyclingSensorDetectionCoordinator.bind(
            to: workoutMirrorManager.store
        )
        _cyclingSensorStore = ObservedObject(
            wrappedValue: cyclingSensorStore
        )
        _cyclingSensorDetectionCoordinator = ObservedObject(
            wrappedValue: cyclingSensorDetectionCoordinator
        )
        _rideDetectionSettingsStore = ObservedObject(
            wrappedValue: rideDetectionSettingsStore
        )
        _rideAutomationCoordinator = ObservedObject(
            wrappedValue: rideAutomationCoordinator
        )
        _watchAvailability = StateObject(wrappedValue: watchAvailability)
        _routeLibrary = ObservedObject(wrappedValue: routeLibrary)
        _workoutStore = ObservedObject(
            wrappedValue: workoutMirrorManager.store
        )
        _liveActivityDiagnostics = ObservedObject(
            wrappedValue: liveActivityDiagnostics
        )
        _rideDiagnosticsRecorder = ObservedObject(
            wrappedValue: rideDiagnosticsRecorder
        )
        _coordinator = StateObject(
            wrappedValue: coordinator
        )
        _mapViewControlState = StateObject(
            wrappedValue: MapViewControlState()
        )
        _offlineMapManager = StateObject(
            wrappedValue: OfflineMapManager(
                diagnosticsRecorder: rideDiagnosticsRecorder
            )
        )
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                let selectionFrame = offlineMapSelectionFrame(in: proxy.size)
                let isCompactHeight = proxy.size.height < 600

                mapView(selectionFrame: offlineMapManager.isMapAreaSelectionActive ? selectionFrame : nil)
                    .ignoresSafeArea()

                if offlineMapManager.isMapAreaSelectionActive {
                    offlineMapSelectionOverlay(selectionFrame: selectionFrame)
                }

                VStack(spacing: 0) {
                    topOverlay

                    if workoutStore.presentation.isWorkoutActive,
                       let issue =
                           liveActivityDiagnostics.issueMessage {
                        liveActivityDiagnosticBanner(issue)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }

                    if coordinator.isNavigating {
                        navigationInstructionBanner(
                            isCompactHeight: isCompactHeight
                        )
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }

                    if rideAutomationCoordinator.startPrompt != nil {
                        rideDetectionStartPrompt
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }

                    if let error = rideAutomationCoordinator.lastError {
                        rideDetectionErrorBanner(error)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }

                    if !offlineMapManager.isMapAreaSelectionActive,
                       shouldShowWorkoutStatusCard {
                        WorkoutCompactCard(
                            store: workoutStore,
                            watchAvailability: watchAvailability,
                            onStart: {
                                _ = workoutMirrorManager
                                    .startOutdoorCyclingOnWatch()
                            },
                            onOpen: {
                                presentedSheet = .workoutDashboard
                            }
                        )
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                    }

                    Spacer()

                    HStack {
                        Spacer()
                        mapControlCluster
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 12)
                    .zIndex(10)

                    bottomOverlay(
                        maxHeight: proxy.size.height * 0.68,
                        isCompactHeight: isCompactHeight
                    )
                }
                .ignoresSafeArea(.container, edges: .bottom)

                if coordinator.bleManager.supportsDeviceSounds &&
                    !offlineMapManager.isMapAreaSelectionActive &&
                    visibleOfflineMapOnboardingStep == nil {
                    DeviceSoundMapButton(bleManager: coordinator.bleManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, 16)
                        .zIndex(9)
                }

                if let onboardingStep = visibleOfflineMapOnboardingStep {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()

                    OfflineMapOnboardingView(
                        manager: offlineMapManager,
                        step: onboardingStep,
                        location: coordinator.currentLocation,
                        locationAuthorizationStatus:
                            coordinator.locationAuthorizationStatus,
                        onRequestLocation: {
                            coordinator.requestLocationAuthorization()
                        },
                        onChooseArea: beginOnboardingMapSelection,
                        onClose: {
                            dismissOfflineMapOnboarding(step: onboardingStep)
                        }
                    )
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(20)
                }

                if let workoutSegmentToast,
                   presentedSheet != .workoutDashboard {
                    VStack {
                        workoutSegmentToastView(workoutSegmentToast)
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(30)
                }
            }
            .alert("Navigation Error", isPresented: $coordinator.alert.isShowing) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(coordinator.alert.message)
            }
            .sheet(
                item: $presentedSheet,
                onDismiss: handleSheetDismissal
            ) { destination in
                presentedSheetContent(for: destination)
            }
        }
        .onAppear {
            onApplicationActiveChange(scenePhase == .active)
            migrateExistingInstallOnboardingIfNeeded()
            isOfflineMapOnboardingStatePrepared = true
            watchAvailability.activate()
            coordinator.setViewingMap(scenePhase == .active)
            updateIdleTimer()
            coordinator.applicationDidBecomeActive()
            workoutMirrorManager.refreshFreshness()
            observedWorkoutSegmentIndex = currentWorkoutSegment?.index
            offlineMapManager.resumePendingMapJobIfNeeded(bleManager: coordinator.bleManager)
            synchronizeRideMetricsSheet()
            presentNearbyBicinoIfEligible()
        }
        .onOpenURL { url in
            offlineMapManager.handleShareURL(url)
        }
        .alert(
            "Add Shared Map?",
            isPresented: Binding(
                get: { offlineMapManager.pendingSharePreview != nil },
                set: { if !$0 { offlineMapManager.dismissPendingShare() } }
            )
        ) {
            Button(
                offlineMapManager.pendingSharePreview.map {
                    offlineMapManager.catalogAvailability(for: $0).claimActionTitle
                } ?? "Add Map"
            ) {
                offlineMapManager.claimPendingShare()
            }
            Button("Cancel", role: .cancel) {
                offlineMapManager.dismissPendingShare()
            }
        } message: {
            if let preview = offlineMapManager.pendingSharePreview {
                let availability = offlineMapManager.catalogAvailability(for: preview)
                let summary =
                    "\(preview.title) · \(preview.features.joined(separator: ", ")) · " +
                    ByteCountFormatter.string(
                        fromByteCount: preview.approximateBytes,
                        countStyle: .file
                    )
                Text(
                    [summary, availability.statusText]
                        .compactMap { $0 }
                        .joined(separator: "\n")
                )
            }
        }
        .onChange(of: presentedSheet) { destination in
            if let destination {
                activeSheetDestination = destination
                isSheetDismissalInFlight = false
            } else if activeSheetDestination != nil {
                isSheetDismissalInFlight = true
            }
        }
        .onChange(of: scenePhase) { newValue in
            onApplicationActiveChange(newValue == .active)
            coordinator.setViewingMap(newValue == .active)
            updateIdleTimer(for: newValue)
            guard newValue == .active else { return }
            coordinator.applicationDidBecomeActive()
            workoutMirrorManager.refreshFreshness()
            offlineMapManager.resumePendingMapJobIfNeeded(bleManager: coordinator.bleManager)
            presentNearbyBicinoIfEligible()
        }
        .onChange(of: coordinator.isNavigating) { _ in
            updateIdleTimer()
            synchronizeRideMetricsSheet()
        }
        .onChange(of: workoutStore.shouldMaintainWorkoutServices) { _ in
            updateIdleTimer()
        }
        .onChange(of: workoutStore.presentation.isWorkoutActive) { _ in
            synchronizeRideMetricsSheet()
        }
        .onChange(of: currentWorkoutSegment?.index) { index in
            guard let index,
                  index != observedWorkoutSegmentIndex else {
                observedWorkoutSegmentIndex = index
                return
            }
            observedWorkoutSegmentIndex = index
            guard scenePhase == .active,
                  presentedSheet != .workoutDashboard,
                  workoutStore.presentation.isWorkoutActive,
                  let segment = currentWorkoutSegment else {
                workoutSegmentToast = nil
                return
            }
            UINotificationFeedbackGenerator()
                .notificationOccurred(.success)
            withAnimation {
                workoutSegmentToast = segment
            }
        }
        .onDisappear {
            coordinator.setViewingMap(false)
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: coordinator.bleManager.isConnected) { _ in
            schedulePendingMapInstallResume()
            presentNearbyBicinoIfEligible()
        }
        .onChange(of: coordinator.bleManager.isConnecting) { _ in
            presentNearbyBicinoIfEligible()
        }
        .onChange(of: coordinator.bleManager.nearbyBicinoCandidate) {
            candidate in
            if candidate == nil,
               case .nearbyBicino = presentedSheet {
                presentedSheet = nil
                return
            }
            presentNearbyBicinoIfEligible()
        }
        .onChange(of: coordinator.bleManager.knownDevices.count) { _ in
            presentNearbyBicinoIfEligible()
        }
        .onChange(of: visibleOfflineMapOnboardingStep) { step in
            if step == nil {
                presentNearbyBicinoIfEligible()
            }
        }
        .onChange(of: coordinator.bleManager.isNavigationReady) { _ in
            schedulePendingMapInstallResume()
            if coordinator.bleManager.isNavigationReady {
                if presentedSheet == .bikeComputerSetup {
                    presentedSheet = nil
                }
            }
        }
        .onChange(of: offlineMapManager.isMapAreaSelectionActive) { isActive in
            if isActive {
                if presentedSheet == .settings {
                    presentedSheet = nil
                }
                offlineMapSelectionWidth = nil
                offlineMapSelectionHeight = nil
                offlineMapSelectionCenterY = nil
            } else {
                offlineMapSelectionDragStartFrame = nil
                presentNearbyBicinoIfEligible()
            }
        }
        .task(id: deviceMapMissingCandidate) {
            guard deviceMapMissingCandidate else {
                confirmedDeviceMapMissing = false
                return
            }

            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }

            guard deviceMapMissingCandidate else { return }
            confirmedDeviceMapMissing = true
        }
        .task(id: workoutSegmentToast?.index) {
            guard let index = workoutSegmentToast?.index else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard workoutSegmentToast?.index == index else { return }
            withAnimation {
                workoutSegmentToast = nil
            }
        }
    }

    private func liveActivityDiagnosticBanner(
        _ message: String
    ) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            }
            .accessibilityIdentifier("liveActivityDiagnostic")
    }

    private var rideDetectionStartPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Cycling detected", systemImage: "bicycle")
                .font(.headline)
            Text("Start an Outdoor Cycling workout on Apple Watch?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(
                "Times out in \(rideAutomationCoordinator.promptSecondsRemaining)s"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack {
                Button("Not Now", role: .cancel) {
                    rideAutomationCoordinator.dismissStartPrompt()
                }
                Spacer()
                Button("Start Ride") {
                    rideAutomationCoordinator.acceptStartPrompt()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
    }

    private func rideDetectionErrorBanner(
        _ error: RideAutomationResult
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(rideDetectionErrorMessage(error))
                .font(.subheadline)
            Spacer()
            Button("Dismiss") {
                rideAutomationCoordinator.dismissError()
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .foregroundStyle(.orange)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("rideDetectionError")
    }

    private func rideDetectionErrorMessage(
        _ error: RideAutomationResult
    ) -> String {
        switch error {
        case .watchUnavailable:
            return "Open Bicino on iPhone and make sure Apple Watch is reachable."
        case .sessionMismatch:
            return "The detected ride no longer matches the active workout."
        case .rejected:
            return "The ride action was not accepted."
        case .stale:
            return "The ride action expired before it could be confirmed."
        case .none, .accepted:
            return "The ride action could not be completed."
        }
    }

    @ViewBuilder
    private func presentedSheetContent(
        for destination: ContentSheetDestination
    ) -> some View {
        switch destination {
        case .settings:
            SettingsView(
                locationAuthorizationStatus:
                    coordinator.locationAuthorizationStatus,
                locationAccuracyAuthorization:
                    coordinator.locationAccuracyAuthorization,
                currentLocation: coordinator.currentLocation,
                isNavigationActive: coordinator.isNavigating,
                offlineMapManager: offlineMapManager,
                firmwareUpdateManager: coordinator.firmwareUpdateManager,
                routeLibrary: routeLibrary,
                watchAvailability: watchAvailability,
                cyclingSensorStore: cyclingSensorStore,
                cyclingSensorDetectionCoordinator:
                    cyclingSensorDetectionCoordinator,
                rideDetectionSettingsStore:
                    rideDetectionSettingsStore,
                rideDiagnosticsRecorder: rideDiagnosticsRecorder,
                onRequestLocationAuthorization: {
                    coordinator.requestLocationAuthorization()
                },
                onStartTestNavigation: { destination in
                    coordinator.startNavigation(
                        from: .currentLocation,
                        to: .query(destination),
                        transportType: RouteTransportTypes.cycling,
                        isTestMode: true
                    )
                }
            )
            .environmentObject(coordinator.bleManager)
            .presentationDetents([.large])
            .presentationBackgroundInteraction(.disabled)

        case .bikeComputerSetup:
            NavigationView {
                BikeComputersSettingsView(
                    sensorStore: cyclingSensorStore,
                    sensorDetectionCoordinator:
                        cyclingSensorDetectionCoordinator,
                    startsBikeComputerDiscoveryOnAppear: true
                )
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") {
                                presentedSheet = nil
                            }
                        }
                    }
            }
            .environmentObject(coordinator.bleManager)
            .presentationDetents([.large])
            .presentationBackgroundInteraction(.disabled)

        case .sensorSettings:
            NavigationView {
                BikeComputersSettingsView(
                    sensorStore: cyclingSensorStore,
                    sensorDetectionCoordinator:
                        cyclingSensorDetectionCoordinator,
                    focusSensorsOnAppear: true
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            presentedSheet = nil
                        }
                    }
                }
            }
            .environmentObject(coordinator.bleManager)
            .presentationDetents([.large])
            .presentationBackgroundInteraction(.disabled)

        case .nearbyBicino(let peripheralIdentifier):
            if let candidate = coordinator.bleManager.nearbyCandidate(
                peripheralIdentifier: peripheralIdentifier
            ) {
                NearbyBicinoSetupSheet(candidate: candidate)
                    .environmentObject(coordinator.bleManager)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.hidden)
                    .presentationBackgroundInteraction(.disabled)
            }

        case .workoutDashboard:
            WorkoutDashboardView(
                store: workoutStore,
                watchAvailability: watchAvailability,
                onStart: {
                    _ = workoutMirrorManager.startOutdoorCyclingOnWatch()
                },
                onPause: workoutMirrorManager.pause,
                onResume: workoutMirrorManager.resume,
                onMarkSegment: workoutMirrorManager.markSegment,
                onEndAndSave: workoutMirrorManager.endAndSave,
                onDiscard: workoutMirrorManager.discard,
                onDone: workoutMirrorManager.resetTerminalPresentation
            )
            .presentationDetents([.large])
            .presentationBackgroundInteraction(.disabled)

        case .rideMetrics:
            rideMetricsPanel(
                isCompactHeight: false,
                isSheetExpanded: rideMetricsDetent == .large
            )
            .presentationDetents(
                [.rideMetricsCompact, .large],
                selection: $rideMetricsDetent
            )
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            .presentationBackgroundInteraction(
                .enabled(upThrough: .rideMetricsCompact)
            )
            .presentationContentInteraction(.resizes)
            .presentationCornerRadius(32)
            .interactiveDismissDisabled()

        }
    }

    private func synchronizeRideMetricsSheet() {
        if workoutStore.presentation.isWorkoutActive {
            guard presentedSheet == nil else { return }
            rideMetricsDetent = .rideMetricsCompact
            presentedSheet = .rideMetrics
        } else if presentedSheet == .rideMetrics {
            presentedSheet = nil
        }
    }

    private func restoreRideMetricsSheetIfNeeded() {
        guard workoutStore.presentation.isWorkoutActive else {
            isSheetDismissalInFlight = false
            presentNearbyBicinoIfEligible()
            return
        }
        Task { @MainActor in
            await Task.yield()
            guard presentedSheet == nil,
                  workoutStore.presentation.isWorkoutActive else {
                isSheetDismissalInFlight = false
                presentNearbyBicinoIfEligible()
                return
            }
            rideMetricsDetent = .rideMetricsCompact
            activeSheetDestination = .rideMetrics
            presentedSheet = .rideMetrics
            isSheetDismissalInFlight = false
        }
    }

    private func handleSheetDismissal() {
        isSheetDismissalInFlight = true
        let dismissedDestination = activeSheetDestination
        activeSheetDestination = nil
        if case .nearbyBicino(let peripheralIdentifier) =
            dismissedDestination {
            coordinator.bleManager.dismissNearbyBicinoCandidate(
                peripheralIdentifier: peripheralIdentifier
            )
        }
        switch SensorSettingsRoutingPolicy.dismissalDecision(
            hasQueuedSheet: queuedSheetAfterDismiss != nil,
            isWorkoutActive: workoutStore.presentation.isWorkoutActive
        ) {
        case .presentQueuedSheet:
            guard let queuedSheetAfterDismiss else { return }
            self.queuedSheetAfterDismiss = nil
            Task { @MainActor in
                await Task.yield()
                guard presentedSheet == nil else {
                    isSheetDismissalInFlight = false
                    return
                }
                activeSheetDestination = queuedSheetAfterDismiss
                presentedSheet = queuedSheetAfterDismiss
                isSheetDismissalInFlight = false
            }
        case .restoreRideMetrics:
            restoreRideMetricsSheetIfNeeded()
        case .doNothing:
            isSheetDismissalInFlight = false
            presentNearbyBicinoIfEligible()
        }
    }

    private func presentNearbyBicinoIfEligible() {
        guard let candidate =
                coordinator.bleManager.nearbyBicinoCandidate,
              Date().timeIntervalSince(candidate.lastSeenAt) <=
                BLEDiscoveryFreshnessPolicy.maximumAge,
              NearbyBicinoPresentationPolicy.shouldPresent(
                isApplicationActive: scenePhase == .active,
                knownDeviceCount:
                    coordinator.bleManager.knownDevices.count,
                hasActiveBLESession:
                    coordinator.bleManager.hasActiveTransportSession,
                hasBlockingPresentation:
                    presentedSheet != nil ||
                    activeSheetDestination != nil ||
                    isSheetDismissalInFlight ||
                    queuedSheetAfterDismiss != nil ||
                    visibleOfflineMapOnboardingStep != nil,
                isMapAreaSelectionActive:
                    offlineMapManager.isMapAreaSelectionActive,
                // A sealed candidate suppresses additional scanning, but is
                // still eligible for this one presentation.
                isSuppressed: false
              ) else { return }
        coordinator.bleManager.markNearbyBicinoCandidatePresented(
            peripheralIdentifier: candidate.peripheralIdentifier
        )
        let destination = ContentSheetDestination.nearbyBicino(
            peripheralIdentifier: candidate.peripheralIdentifier
        )
        activeSheetDestination = destination
        presentedSheet = destination
    }

    private func openSensorSettings() {
        cyclingSensorDetectionCoordinator.prepareForPromptNavigation()
        switch SensorSettingsRoutingPolicy.openDecision(
            hasPresentedSheet: presentedSheet != nil,
            isSensorSettingsPresented: presentedSheet == .sensorSettings
        ) {
        case .presentImmediately:
            presentedSheet = .sensorSettings
        case .dismissAndQueue:
            queuedSheetAfterDismiss = .sensorSettings
            presentedSheet = nil
        case .unchanged:
            break
        }
    }

    private var currentWorkoutSegment: WorkoutCompletedSegmentV1? {
        (workoutStore.presentation.finalSnapshot
            ?? workoutStore.presentation.snapshot).lastCompletedSegment
    }

    private func workoutSegmentToastView(
        _ segment: WorkoutCompletedSegmentV1
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.checkered")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Segment \(segment.index)")
                    .font(.subheadline.weight(.semibold))
                Text(workoutSegmentSummary(segment))
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

    private func workoutSegmentSummary(
        _ segment: WorkoutCompletedSegmentV1
    ) -> String {
        let duration = WorkoutValueFormatter.duration(segment.duration)
        guard let distance = segment.distanceMeters else {
            return duration
        }
        return "\(duration)  •  \(WorkoutValueFormatter.distance(distance)) \(WorkoutValueFormatter.distanceUnit(distance))"
    }

    private func updateIdleTimer(for phase: ScenePhase? = nil) {
        RideIdleTimerController.update(
            isNavigating: coordinator.isNavigating,
            isWorkoutActive: workoutStore.shouldMaintainWorkoutServices,
            isApplicationActive: (phase ?? scenePhase) == .active
        ) {
            UIApplication.shared.isIdleTimerDisabled = $0
        }
    }

    private func schedulePendingMapInstallResume() {
        guard offlineMapManager.hasDownloadedPendingDeviceInstall else { return }
        Task { @MainActor in
            while offlineMapManager.isBusy {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            resumePendingMapInstallIfReady()
        }
    }

    private func resumePendingMapInstallIfReady() {
        guard OfflineMapAutomaticRecoveryTrigger.shouldResume(
            hasPendingInstall: offlineMapManager.hasDownloadedPendingDeviceInstall,
            isBusy: offlineMapManager.isBusy,
            isConnected: coordinator.bleManager.isConnected,
            isNavigationReady: coordinator.bleManager.isNavigationReady
        ) else { return }
        offlineMapManager.resumePendingMapJobIfNeeded(bleManager: coordinator.bleManager)
    }

    private var deviceMapMissingCandidate: Bool {
        OfflineMapOnboardingPolicy.shouldOfferDownload(
            isLocationAuthorized: coordinator.isLocationAuthorized,
            isNavigationReady: coordinator.bleManager.isNavigationReady,
            hasSDCard: coordinator.bleManager.deviceHasSDCard,
            activeMapId: coordinator.bleManager.mapTransferActiveMapId,
            mapFoundForCurrentLocation: coordinator.bleManager.deviceMapFoundForCurrentLocation
        )
    }

    private var offlineMapOnboardingPresentation: OfflineMapOnboardingPresentation {
        OfflineMapOnboardingPolicy.presentation(
            hasCompletedFirstRun: hasCompletedFirstRunWelcome,
            confirmedDeviceMapMissing: confirmedDeviceMapMissing
        )
    }

    private var visibleOfflineMapOnboardingStep: OfflineMapOnboardingStep? {
        guard isOfflineMapOnboardingStatePrepared else { return nil }
        guard !dismissedOfflineMapOnboarding else { return nil }
        guard !offlineMapManager.isMapAreaSelectionActive else { return nil }
        guard !offlineMapManager.isBusy,
              !offlineMapManager.hasPendingMapJob,
              offlineMapManager.currentJob == nil,
              offlineMapManager.downloadedPackURL == nil,
              offlineMapManager.errorMessage == nil else { return nil }
        guard case .step(let step) = offlineMapOnboardingPresentation else {
            return nil
        }
        return step
    }

    private func beginOnboardingMapSelection() {
        hasCompletedFirstRunWelcome = true
        offlineMapManager.beginMapAreaSelection()
    }

    private func dismissOfflineMapOnboarding(
        step: OfflineMapOnboardingStep
    ) {
        dismissedOfflineMapOnboarding = true
        if step == .welcome {
            hasCompletedFirstRunWelcome = true
        }
    }

    private func migrateExistingInstallOnboardingIfNeeded() {
        guard !hasMigratedExistingInstallOnboarding else { return }
        hasMigratedExistingInstallOnboarding = true

        guard !coordinator.bleManager.knownDevices.isEmpty else { return }
        hasCompletedFirstRunWelcome = true
    }

    private var topOverlay: some View {
        HStack(alignment: .center) {
            ConnectionStatusView(
                isConnected: coordinator.isConnected,
                hasRegisteredDevice:
                    !coordinator.bleManager.knownDevices.isEmpty,
                onReconnect: { coordinator.reconnect() }
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .zIndex(10)
    }

    private var mapAppearance: IPhoneMapAppearance {
        IPhoneMapAppearance(
            persistedBaseStyleRawValue: iPhoneMapBaseStyleRawValue,
            usesRealisticElevation: usesRealisticMapElevation
        )
    }

    private var mapBaseStyleBinding: Binding<IPhoneMapBaseStyle> {
        Binding(
            get: { mapAppearance.baseStyle },
            set: { iPhoneMapBaseStyleRawValue = $0.rawValue }
        )
    }

    private var mapControlCluster: some View {
        VStack(alignment: .trailing, spacing: 10) {
            MapCompassControl(controlState: mapViewControlState)
                .frame(width: 44, height: 44)

            mapControlRail
        }
    }

    @ViewBuilder
    private var mapControlRail: some View {
        if #available(iOS 26.0, *) {
            mapControlRailContent
                .glassEffect(
                    .regular.interactive(),
                    in: .rect(cornerRadius: 26)
                )
        } else {
            mapControlRailContent
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(
                        cornerRadius: 26,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
                .shadow(
                    color: .black.opacity(0.14),
                    radius: 7,
                    x: 0,
                    y: 3
                )
        }
    }

    private var mapControlRailContent: some View {
        VStack(spacing: 0) {
            Button(action: { presentedSheet = .settings }) {
                mapControlIcon("gearshape.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

            mapControlDivider

            Button(action: { mapViewControlState.togglePitch() }) {
                mapControlIcon(
                    mapViewControlState.isPitched ? "view.2d" : "view.3d"
                )
            }
            .buttonStyle(.plain)
            .disabled(coordinator.isNavigating)
            .opacity(coordinator.isNavigating ? 0.45 : 1)
            .accessibilityLabel(
                mapViewControlState.isPitched
                    ? "Show map in 2D"
                    : "Show map in 3D"
            )
            .accessibilityValue(
                mapViewControlState.isPitched ? "3D view" : "2D view"
            )
            .accessibilityHint(
                coordinator.isNavigating
                    ? "Available outside navigation."
                    : "Changes the viewing angle. Realistic terrain is controlled in Layers."
            )

            mapControlDivider

            mapLayersMenu
        }
        .frame(width: 52)
        .accessibilityElement(children: .contain)
    }

    private func mapControlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 52, height: 50)
            .contentShape(Rectangle())
    }

    private var mapControlDivider: some View {
        Divider()
            .padding(.horizontal, 11)
    }

    private var mapLayersMenu: some View {
        Menu {
            Section("Base Map") {
                Picker("Base Map", selection: mapBaseStyleBinding) {
                    ForEach(IPhoneMapBaseStyle.allCases) { style in
                        Label(style.title, systemImage: style.systemImage)
                            .tag(style)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            Section("Elevation") {
                Toggle(isOn: $usesRealisticMapElevation) {
                    Label("3D Terrain", systemImage: "mountain.2.fill")
                }
                .accessibilityHint(
                    "Adds realistic elevation; tilt the map to see the terrain."
                )
            }
        } label: {
            mapControlIcon("map.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Layers")
        .accessibilityValue(
            "\(mapAppearance.baseStyle.title), " +
            (usesRealisticMapElevation ? "3D Terrain on" : "3D Terrain off")
        )
    }

    @ViewBuilder
    private func bottomOverlay(
        maxHeight: CGFloat,
        isCompactHeight: Bool
    ) -> some View {
        VStack(spacing: 12) {
            if coordinator.routeCalculation.isCalculating {
                CalculationStatusView(status: coordinator.routeCalculation.status)
                    .padding(.horizontal, 18)
            }

            if coordinator.isNavigating,
               !workoutStore.presentation.isWorkoutActive {
                rideControlPanel(isCompactHeight: isCompactHeight)
            }

            if !coordinator.isNavigating {
                if shouldShowOfflineMapStatusChip {
                    offlineMapStatusChip
                        .padding(.horizontal, 18)
                }

                if !coordinator.routeCalculation.isCalculating {
                    if coordinator.routeAlternatives.isEmpty {
                        routeAndWorkoutStartRow(maxHeight: maxHeight)
                            .padding(.horizontal, 12)
                    } else {
                        routeAlternativesPanel
                            .padding(.horizontal, 12)
                    }
                }
            }
        }
        .padding(.bottom, 24)
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isSearchPanelExpanded)
        .animation(.easeInOut(duration: 0.2), value: coordinator.routeCalculation.isCalculating)
        .animation(.easeInOut(duration: 0.2), value: coordinator.isNavigating)
    }

    private func rideMetricsPanel(
        isCompactHeight: Bool,
        isSheetExpanded: Bool? = nil
    ) -> some View {
        RideMetricsPanel(
            workoutStore: workoutStore,
            watchAvailability: watchAvailability,
            isNavigating: coordinator.isNavigating,
            isCompactHeight: isCompactHeight,
            arrivalDate: coordinator.expectedArrivalDate,
            remainingTime: coordinator.routeRemainingTime,
            remainingDistance: coordinator.routeRemainingDistance,
            onStopNavigation: { coordinator.stopNavigation() },
            onStartWorkout: {
                _ = workoutMirrorManager.startOutdoorCyclingOnWatch()
            },
            onMarkSegment: workoutMirrorManager.markSegment,
            onPauseWorkout: workoutMirrorManager.pause,
            onResumeWorkout: workoutMirrorManager.resume,
            onEndAndSaveWorkout: workoutMirrorManager.endAndSave,
            onDiscardWorkout: workoutMirrorManager.discard,
            enabledSensorCapabilities:
                cyclingSensorStore.enabledCapabilities,
            sensorPrompt:
                cyclingSensorDetectionCoordinator.activePrompt,
            onOpenSensorSettings: openSensorSettings,
            onDismissSensorPrompt:
                cyclingSensorDetectionCoordinator.dismissPrompt,
            isSheetExpanded: isSheetExpanded
        )
    }

    private func rideControlPanel(isCompactHeight: Bool) -> some View {
        rideMetricsPanel(isCompactHeight: isCompactHeight)
            .padding(.horizontal, 12)
    }

    private func routeAndWorkoutStartRow(maxHeight: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            RouteSearchPanel(
                sourceAddress: $sourceAddress,
                destinationAddress: $destinationAddress,
                isExpanded: $isSearchPanelExpanded,
                destinationStore: coordinator.destinationStore,
                currentAddress: coordinator.currentAddress,
                currentLocation: coordinator.currentLocation,
                maxExpandedHeight: maxHeight,
                onStartNavigation: { source, destination, transport in
                    isSearchPanelExpanded = false
                    coordinator.planNavigation(
                        from: source,
                        to: destination,
                        transportType: transport
                    )
                }
            )
            .layoutPriority(0)

            if !isSearchPanelExpanded,
               workoutStore.presentation.canStartNewWorkout {
                WorkoutStartButton(
                    watchAvailability: watchAvailability,
                    action: {
                        _ = workoutMirrorManager.startOutdoorCyclingOnWatch()
                    }
                ) {
                    Label("Start Workout", systemImage: "figure.outdoor.cycle")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 15)
                        .foregroundColor(.white)
                        .background(
                            Color.blue,
                            in: RoundedRectangle(
                                cornerRadius: 24,
                                style: .continuous
                            )
                        )
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .accessibilityLabel("Start workout on Apple Watch")
            }
        }
    }

    private var routeAlternativesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose a route")
                    .font(.headline)
                Spacer()
                Button("Cancel", role: .cancel) {
                    coordinator.cancelRoutePlan()
                }
                .font(.subheadline)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(coordinator.routeAlternatives) { alternative in
                        let selected =
                            coordinator.selectedRouteAlternativeID == alternative.id
                        Button {
                            coordinator.selectRouteAlternative(alternative.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(alternative.title)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(routeAlternativeDetails(alternative))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                selected ? Color.blue.opacity(0.18) :
                                    Color.secondary.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        selected ? Color.blue : Color.clear,
                                        lineWidth: 2
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    coordinator.startSelectedRoute()
                } label: {
                    Label("Start", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(coordinator.selectedRouteAlternativeID == nil)

                Button { } label: {
                    Label("Save Offline", systemImage: "applewatch")
                }
                .buttonStyle(.bordered)
                .disabled(true)
                .accessibilityHint(
                    "MapKit routes cannot be stored offline until an approved route provider is configured."
                )
            }

            if let selected = coordinator.routeAlternatives.first(where: {
                $0.id == coordinator.selectedRouteAlternativeID
            }), !selected.advisoryNotices.isEmpty {
                Label(
                    selected.advisoryNotices.joined(separator: " · "),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(2)
            }

            Text("Offline saving needs an approved route source.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

    private func routeAlternativeDetails(
        _ alternative: NavigationRouteAlternativeV1
    ) -> String {
        let distance = Measurement(
            value: alternative.distanceMeters / 1_000,
            unit: UnitLength.kilometers
        )
        let formatter = MeasurementFormatter()
        formatter.unitOptions = .providedUnit
        formatter.numberFormatter.maximumFractionDigits = 1
        let minutes = max(Int((alternative.expectedTravelTime / 60).rounded()), 1)
        return "\(formatter.string(from: distance)) · \(minutes) min"
    }

    private var shouldShowWorkoutStatusCard: Bool {
        !workoutStore.presentation.isWorkoutActive
            && workoutStore.presentation.connectionState != .idle
    }

    private func navigationInstructionBanner(
        isCompactHeight: Bool
    ) -> some View {
        NavigationInstructionBanner(
            iconID: coordinator.currentIconID,
            distanceToManeuver: coordinator.distanceToManeuver,
            instruction: coordinator.currentInstruction,
            isCompactHeight: isCompactHeight
        )
    }

    private var shouldShowOfflineMapStatusChip: Bool {
        guard !isOnlyCheckingForServerMaps else {
            return false
        }
        return offlineMapManager.isBusy ||
            offlineMapManager.hasPendingMapJob ||
            offlineMapManager.currentJob != nil ||
            offlineMapManager.downloadedPackURL != nil ||
            offlineMapManager.errorMessage != nil
    }

    private var isOnlyCheckingForServerMaps: Bool {
        offlineMapManager.isServerRecoveryCheckPending
            && offlineMapManager.currentJob == nil
            && offlineMapManager.downloadedPackURL == nil
            && offlineMapManager.errorMessage == nil
    }

    private var offlineMapStatusChip: some View {
        ActionStatusChip(
            title: offlineMapStatusTitle,
            subtitle: "Open Map Settings",
            systemImage: offlineMapManager.downloadedPackURL == nil
                ? "map"
                : "checkmark.circle.fill",
            tint: offlineMapManager.downloadedPackURL == nil
                ? .accentColor
                : .green,
            progress: offlineMapManager.isBusy
                ? offlineMapManager.activityProgress
                : nil,
            action: {
                presentedSheet = .settings
            }
        )
        .accessibilityLabel("Offline map download status")
    }

    private var offlineMapStatusTitle: String {
        if let error = offlineMapManager.errorMessage, !error.isEmpty {
            return "Map download needs attention"
        }
        if offlineMapManager.downloadedPackURL != nil {
            return "Map pack ready to upload"
        }
        if !offlineMapManager.statusMessage.isEmpty {
            return offlineMapManager.statusMessage
        }
        return "Preparing offline map"
    }
    
    // MARK: - Map View
    
    private func mapView(selectionFrame: CGRect?) -> some View {
        let canSelectDestination = !coordinator.isNavigating && !offlineMapManager.isMapAreaSelectionActive

        return MapViewContainer(
            appearance: mapAppearance,
            controlState: mapViewControlState,
            location: coordinator.currentLocation,
            route: coordinator.currentRoute ?? coordinator.routePreview,
            simulatedPosition: coordinator.simulatedPosition,
            isSimulationMode: coordinator.isSimulationMode,
            isNavigating: coordinator.isNavigating,
            isUserLocationAuthorized: coordinator.isLocationAuthorized,
            offlineMapSelectionFrame: selectionFrame,
            onMapTapped: {
                if isSearchPanelExpanded {
                    isSearchPanelExpanded = false
                }
            },
            onOfflineMapSelectionBoundsChanged: { bounds in
                offlineMapManager.updateMapAreaSelection(bounds: bounds)
            },
            onDestinationSelected: canSelectDestination ? MapDestinationSelection.handler(
                store: coordinator.destinationStore,
                navigate: { destination, mapLocation in
                    coordinator.handleDestinationSelection(destination: destination, mapLocation: mapLocation)
                }
            ) : nil
        )
    }

    private func offlineMapSelectionFrame(in size: CGSize) -> CGRect {
        let defaultLength = defaultOfflineMapSelectionSideLength(in: size)
        let width = offlineMapSelectionWidth ?? defaultLength
        let height = offlineMapSelectionHeight ?? defaultLength
        let centerY = offlineMapSelectionCenterY ?? size.height / 2
        return CGRect(
            x: (size.width - width) / 2,
            y: centerY - height / 2,
            width: width,
            height: height
        )
    }

    private func defaultOfflineMapSelectionSideLength(in size: CGSize) -> CGFloat {
        min(max(size.width - 48, 180), min(360, size.height * 0.46))
    }

    private func offlineMapSelectionOverlay(selectionFrame: CGRect) -> some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.10))
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white, lineWidth: 2)
                )
                .frame(width: selectionFrame.width, height: selectionFrame.height)
                .position(x: selectionFrame.midX, y: selectionFrame.midY)
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 2)
                .allowsHitTesting(false)

            offlineMapSelectionResizeHandle(edge: .top, selectionFrame: selectionFrame)
                .position(x: selectionFrame.midX, y: selectionFrame.minY)

            offlineMapSelectionResizeHandle(edge: .bottom, selectionFrame: selectionFrame)
                .position(x: selectionFrame.midX, y: selectionFrame.maxY)

            HStack(spacing: 12) {
                Button {
                    offlineMapManager.cancelMapAreaSelection()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
                .buttonStyle(.bordered)

                Button {
                    offlineMapManager.createJobFromSelectedMapArea()
                } label: {
                    Label("Download Area", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(offlineMapManager.selectedMapBounds == nil)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 70)
        }
        .ignoresSafeArea()
        .zIndex(20)
    }

    private func offlineMapSelectionResizeHandle(
        edge: OfflineMapSelectionResizeEdge,
        selectionFrame: CGRect
    ) -> some View {
        Capsule()
            .fill(.regularMaterial)
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.8), lineWidth: 1)
            )
            .frame(width: 92, height: 28)
            .overlay(
                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.primary)
            )
            .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 2)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        resizeOfflineMapSelection(
                            edge: edge,
                            translation: value.translation.height,
                            currentFrame: selectionFrame
                        )
                    }
                    .onEnded { _ in
                        offlineMapSelectionDragStartFrame = nil
                    }
            )
            .accessibilityLabel(edge == .top ? "Resize map area top edge" : "Resize map area bottom edge")
    }

    private func resizeOfflineMapSelection(
        edge: OfflineMapSelectionResizeEdge,
        translation: CGFloat,
        currentFrame: CGRect
    ) {
        let startFrame = offlineMapSelectionDragStartFrame ?? currentFrame
        if offlineMapSelectionDragStartFrame == nil {
            offlineMapSelectionDragStartFrame = startFrame
        }

        let minHeight: CGFloat = 160
        let maxHeight = min(UIScreen.main.bounds.height - 180, 640)
        let rawHeight: CGFloat
        let fixedEdge: CGFloat

        switch edge {
        case .top:
            fixedEdge = startFrame.maxY
            rawHeight = startFrame.height - translation
            let height = min(max(rawHeight, minHeight), maxHeight)
            offlineMapSelectionWidth = startFrame.width
            offlineMapSelectionHeight = height
            offlineMapSelectionCenterY = fixedEdge - height / 2
        case .bottom:
            fixedEdge = startFrame.minY
            rawHeight = startFrame.height + translation
            let height = min(max(rawHeight, minHeight), maxHeight)
            offlineMapSelectionWidth = startFrame.width
            offlineMapSelectionHeight = height
            offlineMapSelectionCenterY = fixedEdge + height / 2
        }
    }
}

private struct DeviceSoundMapButton: View {
    @ObservedObject var bleManager: BLEManager

    var body: some View {
        Button {
            bleManager.playSelectedDeviceSound()
        } label: {
            Image(systemName: bleManager.selectedDeviceSound.systemImage)
                .font(.title3.weight(.semibold))
                .foregroundColor(.accentColor)
                .frame(width: 52, height: 52)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 5, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!bleManager.isNavigationReady)
        .opacity(bleManager.isNavigationReady ? 1 : 0.5)
        .accessibilityLabel("Play \(bleManager.selectedDeviceSound.title)")
    }
}

private enum OfflineMapSelectionResizeEdge {
    case top
    case bottom
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(workoutMirrorManager: WorkoutMirrorManager())
    }
}
