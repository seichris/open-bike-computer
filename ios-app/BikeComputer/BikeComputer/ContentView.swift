//
//  ContentView.swift
//  BikeComputer
//
//  Main view for the Bike Computer app
//

import SwiftUI
import MapKit
import UIKit

private enum ContentSheetDestination: String, Identifiable {
    case settings
    case bikeComputerSetup
    case workoutDashboard
    case rideMetrics

    var id: String { rawValue }
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
    @StateObject private var offlineMapManager = OfflineMapManager()
    @StateObject private var watchAvailability: WorkoutWatchAvailabilityMonitor
    @ObservedObject private var workoutStore: WorkoutMetricsStore
    private let workoutMirrorManager: WorkoutMirrorManager
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var sourceAddress = ""
    @State private var destinationAddress = ""
    @State private var presentedSheet: ContentSheetDestination?
    @State private var rideMetricsDetent = PresentationDetent.rideMetricsCompact
    @State private var workoutSegmentToast: WorkoutCompletedSegmentV1?
    @State private var observedWorkoutSegmentIndex: UInt32?
    @State private var isSearchPanelExpanded = false
    @State private var dismissedOfflineMapOnboarding = false
    @State private var confirmedDeviceMapMissing = false
    @State private var isOfflineMapOnboardingStatePrepared = false
    @AppStorage("offlineMapOnboarding.firstRunCompleted.v1")
    private var hasCompletedFirstRunMapOnboarding = false
    @AppStorage("offlineMapOnboarding.locationStepCompleted.v1")
    private var hasAdvancedPastMapOnboardingLocation = false
    @AppStorage("offlineMapOnboarding.existingInstallMigrationCompleted.v1")
    private var hasMigratedExistingInstallOnboarding = false
    @State private var offlineMapSelectionWidth: CGFloat?
    @State private var offlineMapSelectionHeight: CGFloat?
    @State private var offlineMapSelectionCenterY: CGFloat?
    @State private var offlineMapSelectionDragStartFrame: CGRect?

    @MainActor
    init(
        workoutMirrorManager: WorkoutMirrorManager,
        coordinator: BikeComputerCoordinator? = nil,
        watchAvailability: WorkoutWatchAvailabilityMonitor? = nil
    ) {
        let watchAvailability = watchAvailability
            ?? WorkoutWatchAvailabilityMonitor()
        let coordinator = coordinator ?? BikeComputerCoordinator(
            destinationStore: SavedDestinationStore(),
            workoutMetricsStore: workoutMirrorManager.store
        )
        self.workoutMirrorManager = workoutMirrorManager
        _watchAvailability = StateObject(wrappedValue: watchAvailability)
        _workoutStore = ObservedObject(
            wrappedValue: workoutMirrorManager.store
        )
        _coordinator = StateObject(
            wrappedValue: coordinator
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

                    if coordinator.isNavigating {
                        navigationInstructionBanner(
                            isCompactHeight: isCompactHeight
                        )
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                    }

                    if !offlineMapManager.isMapAreaSelectionActive,
                       shouldShowWorkoutStatusCard {
                        WorkoutCompactCard(
                            store: workoutStore,
                            watchAvailability: watchAvailability,
                            onStart: workoutMirrorManager.startOutdoorCyclingOnWatch,
                            onOpen: {
                                presentedSheet = .workoutDashboard
                            }
                        )
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                    }

                    Spacer()

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
                        bleManager: coordinator.bleManager,
                        step: onboardingStep,
                        location: coordinator.currentLocation,
                        isLocationAuthorized: coordinator.isLocationAuthorized,
                        onRequestLocation: advancePastLocationAndRequestAccess,
                        onSkipLocation: advancePastLocation,
                        onConnectDevice: {
                            presentedSheet = .bikeComputerSetup
                        },
                        onCheckDeviceMaps: {
                            _ = coordinator.bleManager.requestMapTransferStatus()
                            _ = coordinator.bleManager.requestDeviceTransferStatus()
                        },
                        onChooseArea: beginOnboardingMapSelection,
                        onClose: dismissOfflineMapOnboarding
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
                onDismiss: restoreRideMetricsSheetIfNeeded
            ) { destination in
                presentedSheetContent(for: destination)
            }
        }
        .onAppear {
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
        }
        .onChange(of: scenePhase) { newValue in
            coordinator.setViewingMap(newValue == .active)
            updateIdleTimer(for: newValue)
            guard newValue == .active else { return }
            coordinator.applicationDidBecomeActive()
            workoutMirrorManager.refreshFreshness()
            offlineMapManager.resumePendingMapJobIfNeeded(bleManager: coordinator.bleManager)
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
        .task(id: offlineMapOnboardingPresentation) {
            guard offlineMapOnboardingPresentation == .completeFirstRun else {
                return
            }
            hasCompletedFirstRunMapOnboarding = true
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

    @ViewBuilder
    private func presentedSheetContent(
        for destination: ContentSheetDestination
    ) -> some View {
        switch destination {
        case .settings:
            SettingsView(
                locationAuthorized: coordinator.isLocationAuthorized,
                currentLocation: coordinator.currentLocation,
                offlineMapManager: offlineMapManager,
                firmwareUpdateManager: coordinator.firmwareUpdateManager,
                watchAvailability: watchAvailability,
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
                BikeComputersSettingsView()
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

        case .workoutDashboard:
            WorkoutDashboardView(
                store: workoutStore,
                watchAvailability: watchAvailability,
                onStart: workoutMirrorManager.startOutdoorCyclingOnWatch,
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
        guard workoutStore.presentation.isWorkoutActive else { return }
        Task { @MainActor in
            await Task.yield()
            guard presentedSheet == nil,
                  workoutStore.presentation.isWorkoutActive else {
                return
            }
            rideMetricsDetent = .rideMetricsCompact
            presentedSheet = .rideMetrics
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
            hasCompletedFirstRun: hasCompletedFirstRunMapOnboarding,
            hasAdvancedPastLocation: hasAdvancedPastMapOnboardingLocation,
            isLocationAuthorized: coordinator.isLocationAuthorized,
            isNavigationReady: coordinator.bleManager.isNavigationReady,
            hasSDCard: coordinator.bleManager.deviceHasSDCard,
            activeMapId: coordinator.bleManager.mapTransferActiveMapId,
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

    private func advancePastLocationAndRequestAccess() {
        advancePastLocation()
        coordinator.requestLocationAuthorization()
    }

    private func advancePastLocation() {
        hasAdvancedPastMapOnboardingLocation = true
    }

    private func beginOnboardingMapSelection() {
        hasCompletedFirstRunMapOnboarding = true
        offlineMapManager.beginMapAreaSelection()
    }

    private func dismissOfflineMapOnboarding() {
        dismissedOfflineMapOnboarding = true
    }

    private func migrateExistingInstallOnboardingIfNeeded() {
        guard !hasMigratedExistingInstallOnboarding else { return }
        hasMigratedExistingInstallOnboarding = true

        guard !coordinator.bleManager.knownDevices.isEmpty else { return }
        hasAdvancedPastMapOnboardingLocation = true
        hasCompletedFirstRunMapOnboarding = true
    }

    private var topOverlay: some View {
        HStack(alignment: .center, spacing: 12) {
            ConnectionStatusView(
                isConnected: coordinator.isConnected,
                onReconnect: { coordinator.reconnect() }
            )

            Button(action: { presentedSheet = .settings }) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.primary)
                    .shadow(color: .white.opacity(0.8), radius: 2, x: 0, y: 1)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .zIndex(10)
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
                    routeAndWorkoutStartRow(maxHeight: maxHeight)
                        .padding(.horizontal, 12)
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
            onStartWorkout: workoutMirrorManager.startOutdoorCyclingOnWatch,
            onPauseWorkout: workoutMirrorManager.pause,
            onResumeWorkout: workoutMirrorManager.resume,
            onEndAndSaveWorkout: workoutMirrorManager.endAndSave,
            onDiscardWorkout: workoutMirrorManager.discard,
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
                    coordinator.startNavigation(
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
                    action: workoutMirrorManager.startOutdoorCyclingOnWatch
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
        Button {
            presentedSheet = .settings
        } label: {
            HStack(spacing: 10) {
                if offlineMapManager.isBusy {
                    ProgressView(value: offlineMapManager.activityProgress)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: offlineMapManager.downloadedPackURL == nil ? "map" : "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(offlineMapManager.downloadedPackURL == nil ? .accentColor : .green)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(offlineMapStatusTitle)
                        .font(.subheadline.weight(.semibold))
                    Text("Open Map Settings")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
            location: coordinator.currentLocation,
            route: coordinator.currentRoute,
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
