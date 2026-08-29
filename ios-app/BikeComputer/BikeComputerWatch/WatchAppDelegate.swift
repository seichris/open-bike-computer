import Combine
import HealthKit
import WatchKit

@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    let workoutManager: WatchWorkoutManager
    let routeLibrary: WatchRouteLibrary
    let connectivityCoordinator: WatchConnectivityCoordinator
    let controllerCredentialStore: WatchControllerCredentialStore
    let locationService: WatchLocationService
    let deviceLink: WatchDeviceLink
    let navigationManager: WatchNavigationManager
    let navigationSettings: WatchNavigationSettingsStore
    let favoriteStore: WatchFavoriteStore
    private let heartRateZoneSettingsReceiver:
        WatchHeartRateZoneSettingsReceiver
    private let workoutDeviceBridge: WatchWorkoutDeviceBridge
    private let rideAutomationCoordinator: WatchRideAutomationCoordinator
    private var cancellables = Set<AnyCancellable>()

    override init() {
        let locationService = WatchLocationService()
        let workoutManager = WatchWorkoutManager(
            locationService: locationService
        )
        let routeLibrary = WatchRouteLibrary()
        let controllerCredentialStore = WatchControllerCredentialStore()
        let deviceLink = WatchDeviceLink(
            credentialStore: controllerCredentialStore
        )
        let navigationSettings = WatchNavigationSettingsStore()
        let favoriteStore = WatchFavoriteStore()
        let networkMonitor = WatchNetworkPathMonitor()
        let navigationManager = WatchNavigationManager(
            routeLibrary: routeLibrary,
            locationService: locationService,
            deviceLink: deviceLink,
            journalStore: WatchNavigationJournalStore(),
            settingsStore: navigationSettings,
            onlineProvider: WatchOnlineRouteProvider(),
            networkMonitor: networkMonitor
        )
        let connectivityCoordinator = WatchConnectivityCoordinator(
            routeLibrary: routeLibrary,
            controllerCredentialStore: controllerCredentialStore
        )
        self.workoutManager = workoutManager
        self.routeLibrary = routeLibrary
        self.connectivityCoordinator = connectivityCoordinator
        self.controllerCredentialStore = controllerCredentialStore
        self.locationService = locationService
        self.deviceLink = deviceLink
        self.navigationManager = navigationManager
        self.navigationSettings = navigationSettings
        self.favoriteStore = favoriteStore
        workoutDeviceBridge = WatchWorkoutDeviceBridge(
            manager: workoutManager,
            deviceLink: deviceLink
        )
        rideAutomationCoordinator = WatchRideAutomationCoordinator(
            manager: workoutManager,
            deviceLink: deviceLink
        )
        heartRateZoneSettingsReceiver = WatchHeartRateZoneSettingsReceiver(
            session: nil,
            applyMaximumHeartRateBPM: { value in
                workoutManager.setMaximumHeartRateBPM(value)
            },
            applyRideDetectionSettings: { settings, generation in
                if let settings, let generation {
                    workoutManager.setRideDetectionSettings(
                        settings,
                        generation: generation
                    )
                } else {
                    workoutManager.clearRideDetectionSettings()
                }
            },
            applyPendingAutomaticStart: { context in
                workoutManager.setPendingAutomaticStartContext(context)
            }
        )
        super.init()
        connectivityCoordinator.onApplicationContext = {
            [weak heartRateZoneSettingsReceiver, weak favoriteStore,
             weak routeLibrary, weak deviceLink] context in
            heartRateZoneSettingsReceiver?.receiveApplicationContext(context)
            favoriteStore?.receiveApplicationContext(context)
            routeLibrary?.receiveApplicationContext(context)
            deviceLink?.receiveApplicationContext(context)
        }
        connectivityCoordinator.onControllerCredentialsChanged = {
            [weak deviceLink] in
            deviceLink?.controllerCredentialsDidChange()
        }
        connectivityCoordinator.onDirectRidePreparationResponse = {
            [weak deviceLink] request, response in
            deviceLink?.directRidePreparationDidRespond(
                request: request,
                response: response
            )
        }
        deviceLink.onDirectRidePreparationChange = {
            [weak connectivityCoordinator] operation, deviceID,
                preparationID in
            connectivityCoordinator?.sendDirectRidePreparation(
                operation: operation,
                deviceID: deviceID,
                preparationID: preparationID
            )
        }
        workoutManager.$setupState
            .sink { [weak workoutManager, weak connectivityCoordinator]
                setupState in
                guard let workoutManager else { return }
                connectivityCoordinator?.publishWorkoutHealthSetup(
                    WorkoutHealthSetupSnapshotV1(
                        state: setupState.connectivityState,
                        canWriteWorkoutRoute:
                            workoutManager.canWriteWorkoutRoute
                    )
                )
            }
            .store(in: &cancellables)
        connectivityCoordinator.activate()
        navigationManager.recoverIfNeeded()
    }

    func handleActiveWorkoutRecovery() {
        workoutManager.handleActiveWorkoutRecovery()
    }

    func applicationDidBecomeActive() {
        routeLibrary.reload()
        connectivityCoordinator.refreshDeviceMetadata()
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        workoutManager.handleWorkoutConfiguration(workoutConfiguration)
    }
}

private extension WatchWorkoutSetupState {
    var connectivityState: WorkoutHealthSetupStateV1 {
        switch self {
        case .checking, .authorizing:
            return .checking
        case .needsAuthorization:
            return .needsAuthorization
        case .ready:
            return .ready
        case .denied:
            return .denied
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        }
    }
}
