import AuthenticationServices
import Combine
import Foundation
import UIKit

@MainActor
protocol StravaOAuthAuthorizing: AnyObject {
    func start(
        _ authorization: StravaOAuthStartV1,
        callback: @escaping @MainActor (URL?, Error?) -> Void
    )
    func cancel()
}

@MainActor
private final class StravaAuthenticationPresentationProvider: NSObject,
    ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap {
            $0 as? UIWindowScene
        }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ??
            scenes.flatMap(\.windows).first ?? UIWindow()
    }
}

@MainActor
final class SystemStravaOAuthAuthorizer: StravaOAuthAuthorizing {
    private let presentationProvider =
        StravaAuthenticationPresentationProvider()
    private var webSession: ASWebAuthenticationSession?

    func start(
        _ authorization: StravaOAuthStartV1,
        callback: @escaping @MainActor (URL?, Error?) -> Void
    ) {
        cancel()
        let startWeb = { [weak self] in
            guard let self else { return }
            let session = ASWebAuthenticationSession(
                url: authorization.webAuthorizationURL,
                callbackURLScheme: authorization.callbackScheme
            ) { url, error in
                Task { @MainActor in callback(url, error) }
            }
            session.presentationContextProvider = presentationProvider
            session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() {
                callback(nil, StravaIntegrationClientError.unavailable)
            }
        }

        guard UIApplication.shared.canOpenURL(
            authorization.appAuthorizationURL
        ) else {
            startWeb()
            return
        }
        UIApplication.shared.open(
            authorization.appAuthorizationURL,
            options: [:]
        ) { opened in
            Task { @MainActor in
                if !opened { startWeb() }
            }
        }
    }

    func cancel() {
        webSession?.cancel()
        webSession = nil
    }
}

nonisolated enum StravaIntegrationActivityV1: Equatable, Sendable {
    case idle
    case checking
    case authorizing
    case importing
    case reloading(UUID)
    case disconnecting

    var isBusy: Bool { self != .idle }
}

nonisolated enum StravaRouteCatalogStateV1: Equatable, Sendable {
    case idle
    case loading
    case loadingMore(loadedRouteCount: Int)
    case loaded
    case empty
    case authorizationExpired
    case failed(String)
}

@MainActor
final class StravaIntegrationCoordinator: ObservableObject {
    static let revalidationInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var capability:
        StravaRouteImportCapabilityV1?
    @Published private(set) var connectionStatus:
        StravaConnectionStatusV1 = .unavailable
    @Published private(set) var activity: StravaIntegrationActivityV1 = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var athleteRoutes: [StravaAthleteRouteSummaryV1] = []
    @Published private(set) var routeCatalogState: StravaRouteCatalogStateV1 = .idle
    @Published private(set) var completedImportSequence: UInt = 0
    @Published private(set) var lastCompletedRouteID: UUID?

    private enum PendingOperation: Equatable {
        case firstImport(StravaRouteURLV1)
        case reload(StravaRouteReloadBookmarkV1)

        var routeID: UUID? {
            switch self {
            case .firstImport: nil
            case .reload(let bookmark): bookmark.routeID
            }
        }

        var routeURL: StravaRouteURLV1? {
            switch self {
            case .firstImport(let routeURL): routeURL
            case .reload(let bookmark): try? bookmark.routeURL()
            }
        }
    }

    private let client: StravaIntegrationClient
    private let routeLibrary: PhoneRouteLibrary
    private let authorizer: any StravaOAuthAuthorizing
    private let callbackScheme: String
    private let now: () -> Date
    private var task: Task<Void, Never>?
    private var taskGeneration: UInt = 0
    private var revalidationTask: Task<Void, Never>?
    private var revalidationGeneration: UInt = 0
    private var routeCatalogTask: Task<Void, Never>?
    private var routeCatalogGeneration: UInt = 0
    private var isRouteCatalogActive = false
    private var pendingOperation: PendingOperation?
    private var oauthSessionID: String?
    private var authorizationGeneration: UInt = 0
    private var didAuthorizePendingOperation = false

    init(
        client: StravaIntegrationClient,
        routeLibrary: PhoneRouteLibrary,
        callbackScheme: String,
        authorizer: (any StravaOAuthAuthorizing)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.routeLibrary = routeLibrary
        self.callbackScheme = callbackScheme
        self.authorizer = authorizer ?? SystemStravaOAuthAuthorizer()
        self.now = now
    }

    var isConfigured: Bool {
        BicinoURLSchemeConfig.isConsistent(
            scheme: callbackScheme,
            serviceURLString:
                OfflineMapServiceConfig.defaultServerURLString
        )
    }

    var isImportAvailable: Bool {
        isConfigured && capability?.isUsable == true
    }

    var isConnected: Bool {
        connectionStatus.connected
    }

    var isRouteCatalogAuthorized: Bool {
        connectionStatus.connected && connectionStatus.canReadPrivateRoutes
    }

    var shouldShowManagement: Bool {
        isConfigured || connectionStatus.connected ||
            !routeLibrary.stravaReloadBookmarks.isEmpty ||
            routeLibrary.routes.contains {
                $0.providerID == RouteProviderPolicyV1.strava.providerID
            }
    }

    func isReloading(routeID: UUID) -> Bool {
        activity == .reloading(routeID)
    }

    func isImporting(externalRouteID: String) -> Bool {
        activity == .importing &&
            pendingOperation?.routeURL?.externalRouteID == externalRouteID
    }

    func clearError() {
        errorMessage = nil
    }

    func activate() {
        routeLibrary.reload()
        refreshAndRevalidate()
    }

    func activateRouteCatalog() {
        isRouteCatalogActive = true
        routeLibrary.reload()
        refreshAndRevalidate()
        startRouteCatalogIfNeeded()
    }

    func deactivateRouteCatalog() {
        isRouteCatalogActive = false
        cancelRouteCatalog()
        athleteRoutes = []
        routeCatalogState = .idle
    }

    func refreshRouteCatalog() {
        guard isRouteCatalogActive else { return }
        cancelRouteCatalog()
        startRouteCatalogIfNeeded(resetRoutes: true)
    }

    func refreshAndRevalidate() {
        guard task == nil, isConfigured else { return }
        let shouldResumeAuthorization = activity == .authorizing
        activity = .checking
        errorMessage = nil
        let generation = nextTaskGeneration()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await self.fetchAuthoritativeState()
                guard self.isCurrentTask(generation), !Task.isCancelled else {
                    return
                }
                self.applyAuthoritativeState(state)
                if shouldResumeAuthorization,
                   self.connectionStatus.connected {
                    self.cancelAuthorizationOnly()
                    self.didAuthorizePendingOperation =
                        self.pendingOperation != nil
                    self.finishTask(generation)
                    if self.pendingOperation != nil {
                        self.executePendingOperation()
                    } else {
                        self.activity = .idle
                        self.startRouteCatalogIfNeeded(resetRoutes: true)
                    }
                    return
                }
                self.finishTask(generation)
                if shouldResumeAuthorization,
                   self.oauthSessionID != nil {
                    self.activity = .authorizing
                    return
                }
                if self.activity == .checking { self.activity = .idle }
                self.startRouteCatalogIfNeeded()
                self.startRevalidationIfNeeded()
            } catch {
                guard self.isCurrentTask(generation) else { return }
                self.finishTask(generation)
                if shouldResumeAuthorization,
                   self.oauthSessionID != nil {
                    self.activity = .authorizing
                    return
                }
                self.fail(error)
            }
        }
    }

    func importRoute(urlString: String) {
        do {
            let routeURL = try StravaRouteURLV1(urlString)
            begin(.firstImport(routeURL))
        } catch {
            fail(error)
        }
    }

    func importRoute(_ route: StravaAthleteRouteSummaryV1) {
        guard route.type.isImportable,
              let routeURL = route.routeURL else {
            fail(StravaIntegrationClientError.routeNotImportable)
            return
        }
        begin(.firstImport(routeURL))
    }

    func reload(_ bookmark: StravaRouteReloadBookmarkV1) {
        do {
            try bookmark.validate()
            begin(.reload(bookmark))
        } catch {
            fail(error)
        }
    }

    func reload(_ route: PlannedRouteSummaryV1) {
        guard let bookmark = routeLibrary.stravaBookmark(routeID: route.id) else {
            fail(PhoneRouteLibraryError.stravaBookmarkMissing)
            return
        }
        reload(bookmark)
    }

    func connect() {
        beginAuthorization(for: nil)
    }

    func disconnectAndDeleteData() {
        guard task == nil, activity == .idle else { return }
        cancelRevalidation()
        cancelRouteCatalog()
        cancelAuthorizationOnly()
        pendingOperation = nil
        didAuthorizePendingOperation = false
        activity = .disconnecting
        errorMessage = nil
        let generation = nextTaskGeneration()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try self.routeLibrary.purge(
                    providerID: RouteProviderPolicyV1.strava.providerID
                )
                try await self.client.disconnect()
                guard self.isCurrentTask(generation), !Task.isCancelled else {
                    return
                }
                self.connectionStatus = .unavailable
                let capability = try? await self.client.capability()
                guard self.isCurrentTask(generation), !Task.isCancelled else {
                    return
                }
                self.capability = capability
                self.finishTask(generation)
                self.activity = .idle
                self.athleteRoutes = []
                self.routeCatalogState = .idle
            } catch {
                guard self.isCurrentTask(generation) else { return }
                self.finishTask(generation)
                self.fail(error)
            }
        }
    }

    func cancelUserOperation() {
        cancelPrimaryTask()
        cancelRevalidation()
        cancelRouteCatalog()
        cancelAuthorizationOnly()
        pendingOperation = nil
        didAuthorizePendingOperation = false
        activity = .idle
    }

    @discardableResult
    func handleOpenURL(_ url: URL) -> Bool {
        guard StravaOAuthCallbackV1.matchesReturnLocation(
            url,
            expectedScheme: callbackScheme
        ) else { return false }
        guard let expectedSessionID = oauthSessionID,
              let callback = StravaOAuthCallbackV1.parse(
                url,
                expectedScheme: callbackScheme,
                expectedSessionID: expectedSessionID
              ) else {
            cancelPrimaryTask()
            cancelAuthorizationOnly()
            fail(StravaIntegrationClientError.oauthSessionInvalid)
            return true
        }
        completeAuthorization(callback)
        return true
    }

    private func begin(_ operation: PendingOperation) {
        guard task == nil, activity == .idle else { return }
        cancelRevalidation()
        pendingOperation = operation
        didAuthorizePendingOperation = false
        errorMessage = nil
        activity = .checking
        let generation = nextTaskGeneration()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await self.fetchAuthoritativeState()
                guard self.isCurrentTask(generation), !Task.isCancelled else {
                    return
                }
                self.applyAuthoritativeState(state)
                self.finishTask(generation)
                guard self.capability?.isUsable == true else {
                    throw StravaIntegrationClientError.unavailable
                }
                if self.connectionStatus.connected {
                    self.executePendingOperation()
                } else {
                    self.beginAuthorization(for: operation)
                }
            } catch {
                guard self.isCurrentTask(generation) else { return }
                self.finishTask(generation)
                self.fail(error)
            }
        }
    }

    private func beginAuthorization(for operation: PendingOperation?) {
        guard task == nil, isConfigured else {
            if !isConfigured { fail(StravaIntegrationClientError.unavailable) }
            return
        }
        if let operation { pendingOperation = operation }
        activity = .authorizing
        errorMessage = nil
        let authorizationGeneration = beginAuthorizationSession()
        let generation = nextTaskGeneration()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let start = try await self.client.startOAuth()
                guard self.isCurrentTask(generation),
                      self.authorizationGeneration == authorizationGeneration,
                      !Task.isCancelled else { return }
                self.oauthSessionID = start.sessionID
                self.authorizer.start(start) { [weak self] url, error in
                    guard let self,
                          self.authorizationGeneration ==
                            authorizationGeneration else { return }
                    if let url {
                        _ = self.handleOpenURL(url)
                    } else if let error {
                        self.cancelAuthorizationOnly()
                        self.fail(error)
                    }
                }
                self.finishTask(generation)
            } catch {
                guard self.isCurrentTask(generation) else { return }
                self.finishTask(generation)
                self.cancelAuthorizationOnly()
                self.fail(error)
            }
        }
    }

    private func completeAuthorization(_ callback: StravaOAuthCallbackV1) {
        cancelAuthorizationOnly()
        cancelPrimaryTask()
        switch callback.result {
        case .connected:
            didAuthorizePendingOperation = true
            activity = .checking
            let generation = nextTaskGeneration()
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let state = try await self.fetchAuthoritativeState()
                    guard self.isCurrentTask(generation),
                          !Task.isCancelled else { return }
                    self.applyAuthoritativeState(state)
                    guard self.connectionStatus.connected else {
                        throw StravaIntegrationClientError.notConnected
                    }
                    self.finishTask(generation)
                    if self.pendingOperation != nil {
                        self.executePendingOperation()
                    } else {
                        self.activity = .idle
                        self.startRouteCatalogIfNeeded(resetRoutes: true)
                    }
                } catch {
                    guard self.isCurrentTask(generation) else { return }
                    self.finishTask(generation)
                    self.fail(error)
                }
            }
        case .denied:
            fail(StravaIntegrationClientError.notConnected)
        case .failed, .invalid:
            fail(StravaIntegrationClientError.oauthSessionInvalid)
        }
    }

    private func executePendingOperation() {
        guard task == nil, var operation = pendingOperation else {
            fail(StravaIntegrationClientError.invalidResponse)
            return
        }
        switch operation {
        case .firstImport:
            activity = .importing
        case .reload(let bookmark):
            activity = .reloading(bookmark.routeID)
            do {
                let updated = try routeLibrary.recordStravaReloadAttempt(
                    bookmark
                )
                operation = .reload(updated)
                pendingOperation = operation
            } catch {
                fail(error)
                return
            }
        }
        guard let routeURL = operation.routeURL else {
            fail(StravaIntegrationClientError.invalidResponse)
            return
        }
        let generation = nextTaskGeneration()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let download = try await self.client.downloadRoute(routeURL)
                guard self.isCurrentTask(generation),
                      !Task.isCancelled else { return }
                let summary: PlannedRouteSummaryV1
                switch operation {
                case .firstImport:
                    summary = try self.routeLibrary.importStravaGPX(
                        download.gpx,
                        receipt: download.receipt
                    )
                case .reload(let bookmark):
                    summary = try self.routeLibrary.reloadStravaGPX(
                        download.gpx,
                        receipt: download.receipt,
                        bookmark: bookmark
                    )
                }
                self.lastCompletedRouteID = summary.id
                self.completedImportSequence &+= 1
                self.pendingOperation = nil
                self.didAuthorizePendingOperation = false
                self.errorMessage = nil
                self.finishTask(generation)
                self.activity = .idle
            } catch let error as StravaIntegrationClientError
                where error.requiresConnection &&
                    !self.didAuthorizePendingOperation {
                guard self.isCurrentTask(generation) else { return }
                self.connectionStatus = .unavailable
                self.finishTask(generation)
                self.beginAuthorization(for: operation)
            } catch {
                guard self.isCurrentTask(generation) else { return }
                if case .reload(let bookmark) = operation {
                    _ = try? self.routeLibrary.recordStravaReloadAttempt(
                        bookmark,
                        failed: true
                    )
                }
                self.pendingOperation = nil
                self.didAuthorizePendingOperation = false
                self.finishTask(generation)
                self.fail(error)
            }
        }
    }

    private typealias AuthoritativeState = (
        capability: StravaRouteImportCapabilityV1,
        connection: StravaConnectionStatusV1
    )

    private func fetchAuthoritativeState() async throws -> AuthoritativeState {
        guard isConfigured else {
            throw StravaIntegrationClientError.unavailable
        }
        let capability = try await client.capability()
        let connection = try await client.connectionStatus()
        return (capability, connection)
    }

    private func applyAuthoritativeState(_ state: AuthoritativeState) {
        capability = state.capability
        connectionStatus = state.connection
    }

    private func startRouteCatalogIfNeeded(resetRoutes: Bool = false) {
        guard isRouteCatalogActive,
              routeCatalogTask == nil,
              connectionStatus.connected,
              capability?.isUsable == true else { return }
        guard connectionStatus.canReadPrivateRoutes else {
            athleteRoutes = []
            routeCatalogState = .authorizationExpired
            return
        }
        if resetRoutes { athleteRoutes = [] }
        routeCatalogState = .loading
        let generation = nextRouteCatalogGeneration()
        routeCatalogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var routes: [StravaAthleteRouteSummaryV1] = []
            var routeIDs: Set<String> = []
            var page = 1
            do {
                while true {
                    let result = try await self.client.athleteRoutes(page: page)
                    guard self.isCurrentRouteCatalog(generation),
                          !Task.isCancelled else { return }
                    guard result.routes.allSatisfy({
                        routeIDs.insert($0.routeID).inserted
                    }) else {
                        throw StravaIntegrationClientError.invalidResponse
                    }
                    routes.append(contentsOf: result.routes)
                    self.athleteRoutes = routes
                    guard let nextPage = result.nextPage else {
                        self.routeCatalogState = routes.isEmpty ? .empty : .loaded
                        self.finishRouteCatalog(generation)
                        return
                    }
                    self.routeCatalogState = .loadingMore(
                        loadedRouteCount: routes.count
                    )
                    page = nextPage
                }
            } catch {
                guard self.isCurrentRouteCatalog(generation),
                      !Task.isCancelled else { return }
                self.finishRouteCatalog(generation)
                if let error = error as? StravaIntegrationClientError,
                   error.requiresConnection {
                    self.connectionStatus = .unavailable
                    self.athleteRoutes = []
                    self.routeCatalogState = .authorizationExpired
                } else {
                    let message = (error as? LocalizedError)?.errorDescription ??
                        "The Strava routes could not be loaded."
                    self.routeCatalogState = .failed(message)
                }
            }
        }
    }

    private func startRevalidationIfNeeded() {
        guard revalidationTask == nil,
              activity == .idle || activity == .checking,
              connectionStatus.connected,
              capability?.isUsable == true else {
            return
        }
        let cutoff = now().addingTimeInterval(-Self.revalidationInterval)
        let activeRouteIDs = Set(routeLibrary.routes.filter {
            $0.providerID == RouteProviderPolicyV1.strava.providerID
        }.map(\.id))
        let bookmarks = routeLibrary.stravaReloadBookmarks.filter {
            activeRouteIDs.contains($0.routeID) &&
                ($0.lastValidationAt ?? .distantPast) <= cutoff
        }
        guard !bookmarks.isEmpty else { return }
        let generation = nextRevalidationGeneration()
        revalidationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishRevalidation(generation) }
            for bookmark in bookmarks {
                guard self.isCurrentRevalidation(generation),
                      !Task.isCancelled else { return }
                do {
                    let routeURL = try bookmark.routeURL()
                    let result = try await self.client.validateRoute(routeURL)
                    guard self.isCurrentRevalidation(generation),
                          !Task.isCancelled else { return }
                    try self.routeLibrary.recordStravaValidation(
                        bookmark,
                        checkedAt: result.checkedAt
                    )
                } catch {
                    guard self.isCurrentRevalidation(generation),
                          !Task.isCancelled else { return }
                    if let error = error as? StravaIntegrationClientError,
                       error.authoritativelyRemovesRoute {
                        self.routeLibrary.expireStravaRoute(
                            id: bookmark.routeID
                        )
                    } else if let error =
                        error as? StravaIntegrationClientError,
                        error.requiresConnection {
                        self.connectionStatus = .unavailable
                        return
                    }
                    // Other failures are transient and must not destroy an
                    // otherwise unexpired offline route.
                    continue
                }
            }
        }
    }

    private func cancelAuthorizationOnly() {
        authorizationGeneration &+= 1
        authorizer.cancel()
        oauthSessionID = nil
    }

    private func beginAuthorizationSession() -> UInt {
        authorizationGeneration &+= 1
        authorizer.cancel()
        oauthSessionID = nil
        return authorizationGeneration
    }

    private func nextTaskGeneration() -> UInt {
        taskGeneration &+= 1
        return taskGeneration
    }

    private func isCurrentTask(_ generation: UInt) -> Bool {
        generation == taskGeneration
    }

    private func finishTask(_ generation: UInt) {
        if isCurrentTask(generation) { task = nil }
    }

    private func cancelPrimaryTask() {
        taskGeneration &+= 1
        task?.cancel()
        task = nil
    }

    private func nextRevalidationGeneration() -> UInt {
        revalidationGeneration &+= 1
        return revalidationGeneration
    }

    private func isCurrentRevalidation(_ generation: UInt) -> Bool {
        generation == revalidationGeneration
    }

    private func finishRevalidation(_ generation: UInt) {
        if isCurrentRevalidation(generation) { revalidationTask = nil }
    }

    private func cancelRevalidation() {
        revalidationGeneration &+= 1
        revalidationTask?.cancel()
        revalidationTask = nil
    }

    private func nextRouteCatalogGeneration() -> UInt {
        routeCatalogGeneration &+= 1
        return routeCatalogGeneration
    }

    private func isCurrentRouteCatalog(_ generation: UInt) -> Bool {
        generation == routeCatalogGeneration
    }

    private func finishRouteCatalog(_ generation: UInt) {
        if isCurrentRouteCatalog(generation) { routeCatalogTask = nil }
    }

    private func cancelRouteCatalog() {
        routeCatalogGeneration &+= 1
        routeCatalogTask?.cancel()
        routeCatalogTask = nil
    }

    private func fail(_ error: Error) {
        if error is CancellationError { return }
        errorMessage = (error as? LocalizedError)?.errorDescription ??
            "The Strava request could not be completed."
        activity = .idle
    }
}
