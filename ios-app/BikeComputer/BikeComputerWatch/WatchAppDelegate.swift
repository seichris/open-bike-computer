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
        heartRateZoneSettingsReceiver = WatchHeartRateZoneSettingsReceiver(
            session: nil,
            applyMaximumHeartRateBPM: { value in
                workoutManager.setMaximumHeartRateBPM(value)
            }
        )
        super.init()
        connectivityCoordinator.onApplicationContext = {
            [weak heartRateZoneSettingsReceiver, weak favoriteStore] context in
            heartRateZoneSettingsReceiver?.receiveApplicationContext(context)
            favoriteStore?.receiveApplicationContext(context)
        }
        connectivityCoordinator.onControllerCredentialsChanged = {
            [weak deviceLink] in
            deviceLink?.controllerCredentialsDidChange()
        }
        connectivityCoordinator.activate()
        navigationManager.recoverIfNeeded()
    }

    func handleActiveWorkoutRecovery() {
        workoutManager.handleActiveWorkoutRecovery()
    }

    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        workoutManager.handleWorkoutConfiguration(workoutConfiguration)
    }
}
