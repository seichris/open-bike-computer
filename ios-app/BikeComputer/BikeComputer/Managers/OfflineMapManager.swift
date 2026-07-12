//
//  OfflineMapManager.swift
//  BikeComputer
//
//  Coordinates offline map platform requests from the settings UI.
//

import CoreLocation
import Combine
import Foundation

private enum OfflineMapDefaults {
    nonisolated static let serverURLKey = "offlineMap.serverURL"
    nonisolated static let apiTokenKey = "offlineMap.apiToken"
    nonisolated static let centerLatitudeKey = "offlineMap.centerLatitude"
    nonisolated static let centerLongitudeKey = "offlineMap.centerLongitude"
    nonisolated static let sideLengthKey = "offlineMap.sideLengthKm"
    nonisolated static let packDisplayNamesKey = "offlineMap.packDisplayNames"
    nonisolated static let lastTransferMapIdKey = "offlineMap.lastTransfer.mapId"
    nonisolated static let lastTransferSessionIdKey = "offlineMap.lastTransfer.sessionId"
    nonisolated static let lastTransferPreviousMapIdKey = "offlineMap.lastTransfer.previousMapId"
    nonisolated static let lastTransferPreviousSessionIdKey = "offlineMap.lastTransfer.previousSessionId"
    nonisolated static let lastTransferPreviousSequenceKey = "offlineMap.lastTransfer.previousSequence"
    nonisolated static let lastTransferAcceptedSequenceKey = "offlineMap.lastTransfer.acceptedSequence"
    nonisolated static let lastTransferOutcomeKey = "offlineMap.lastTransfer.outcome"
    nonisolated static let mapJobPollIntervalNanoseconds: UInt64 = 2_000_000_000
    nonisolated static let activationConfirmationTimeout: TimeInterval = 10 * 60
    nonisolated static let activationPollIntervalNanoseconds: UInt64 = 2_000_000_000
    nonisolated static let legacyServerURLs = [
        "http://rhi0maej6bwo33hn0im6h4lf.178.18.245.246.sslip.io"
    ]
}

nonisolated enum OfflineMapServerIdentity {
    private static let managedIdentity = "managed-production"

    static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        while !components.path.isEmpty && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? trimmed.lowercased()
    }

    static func isManaged(_ value: String?) -> Bool {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        let normalizedValue = normalized(value)
        return ([OfflineMapServiceConfig.productionServerURLString] + OfflineMapDefaults.legacyServerURLs)
            .contains { normalized($0) == normalizedValue }
    }

    static func recoveryKey(_ value: String) -> String {
        isManaged(value) ? managedIdentity : normalized(value)
    }
}

nonisolated enum MapActivationDecision: Equatable {
    case pending(String)
    case installed
    case failed(String)
}

nonisolated struct MapActivationEvaluation: Equatable {
    let decision: MapActivationDecision
    let observedCurrentAttempt: Bool
}

nonisolated enum MapActivationReconciler {
    static func evaluate(expectedMapId: String,
                         sessionId: String,
                         previousMapId: String?,
                         previousSessionId: String?,
                         previousSequence: UInt32?,
                         acceptedSequence: UInt32?,
                         observedCurrentAttempt: Bool,
                         activeMapId: String?,
                         activeSessionId: String?,
                         activationStatus: String?,
                         activationSequence: UInt32?,
                         activationSessionId: String?,
                         activationMapId: String?,
                         activationError: String?) -> MapActivationEvaluation {
        let previousMapId = previousMapId?.isEmpty == false ? previousMapId : nil
        let previousSessionId = previousSessionId?.isEmpty == false ? previousSessionId : nil
        let activeMapId = activeMapId?.isEmpty == false ? activeMapId : nil
        let activeSessionId = activeSessionId?.isEmpty == false ? activeSessionId : nil
        let sessionMatches = activationSessionId == sessionId
        let sequenceAdvanced: Bool
        if let previousSequence, let activationSequence {
            sequenceAdvanced = previousSequence != activationSequence
        } else {
            sequenceAdvanced = false
        }

        let acknowledgedSequenceMatches = acceptedSequence != nil &&
            activationSequence == acceptedSequence
        var observedCurrentAttempt = observedCurrentAttempt ||
            sequenceAdvanced || acknowledgedSequenceMatches
        if sessionMatches, activationStatus == "activating" {
            observedCurrentAttempt = true
        }

        if sessionMatches, observedCurrentAttempt {
            if activationStatus == "failed" {
                return MapActivationEvaluation(
                    decision: .failed(activationError ?? "device reported activation failure"),
                    observedCurrentAttempt: true
                )
            }
            if activationStatus == "installed" {
                if let activationMapId,
                   !activationMapId.isEmpty,
                   activationMapId != expectedMapId {
                    return MapActivationEvaluation(
                        decision: .failed(
                            "device activated \(activationMapId) instead of \(expectedMapId)"
                        ),
                        observedCurrentAttempt: true
                    )
                }
                return MapActivationEvaluation(
                    decision: .installed,
                    observedCurrentAttempt: true
                )
            }
        }

        if activeMapId == expectedMapId,
           activeSessionId == sessionId,
           (!sessionMatches ||
            (previousSessionId != nil && previousSessionId != sessionId)) {
            return MapActivationEvaluation(
                decision: .installed,
                observedCurrentAttempt: observedCurrentAttempt
            )
        }

        if let previousMapId,
           activeMapId == expectedMapId,
           previousMapId != expectedMapId {
            return MapActivationEvaluation(
                decision: .installed,
                observedCurrentAttempt: observedCurrentAttempt
            )
        }

        let state: String
        if sessionMatches, let activationStatus, !activationStatus.isEmpty {
            state = activationStatus
        } else if activeMapId == expectedMapId {
            state = "active map is \(expectedMapId); waiting for current activation"
        } else {
            state = "waiting for activation status"
        }
        return MapActivationEvaluation(
            decision: .pending(state),
            observedCurrentAttempt: observedCurrentAttempt
        )
    }
}

nonisolated enum MapActivationTransport {
    static func isAmbiguousResponseError(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return nsError.code == NSURLErrorNetworkConnectionLost ||
            nsError.code == NSURLErrorTimedOut
    }
}

nonisolated enum MapTransferSessionIdentity {
    static func make(mapId: String, manifestData: Data) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        let sanitized = mapId.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let value = String(sanitized).trimmingCharacters(
            in: CharacterSet(charactersIn: ".-")
        )
        if value.isEmpty {
            return UUID().uuidString.lowercased()
        }
        let manifestDigest = FirmwareUpdateManager.sha256Hex(manifestData)
        let suffix = String(manifestDigest.prefix(16))
        return "\(String(value.prefix(63)))-\(suffix)"
    }
}

nonisolated enum OfflineMapPollingRetryPolicy {
    static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError {
            return false
        }
        if let platformError = error as? OfflineMapPlatformError,
           case .serverStatus(let status, _) = platformError {
            return status == 408 || status == 425 || status == 429 || (500...599).contains(status)
        }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .resourceUnavailable,
            .dataNotAllowed,
        ].contains(urlError.code)
    }

    static func delayNanoseconds(failureCount: Int) -> UInt64 {
        let exponent = min(max(failureCount - 1, 0), 4)
        let seconds = min(2 * (1 << exponent), 30)
        return UInt64(seconds) * 1_000_000_000
    }
}

@MainActor
enum OfflineMapJobPoller {
    static func waitForReady(
        jobId: String,
        pollIntervalNanoseconds: UInt64,
        fetch: @escaping (String) async throws -> OfflineMapJob,
        sleep: @escaping (UInt64) async throws -> Void,
        onUpdate: @escaping (OfflineMapJob) -> Void,
        onRetry: @escaping () -> Void
    ) async throws -> OfflineMapJob {
        var consecutiveFailures = 0
        while !Task.isCancelled {
            let job: OfflineMapJob
            do {
                job = try await fetch(jobId)
                consecutiveFailures = 0
            } catch {
                guard OfflineMapPollingRetryPolicy.shouldRetry(error) else { throw error }
                consecutiveFailures += 1
                onRetry()
                try await sleep(
                    OfflineMapPollingRetryPolicy.delayNanoseconds(
                        failureCount: consecutiveFailures
                    )
                )
                continue
            }

            onUpdate(job)
            if job.status == "ready", job.mapId != nil {
                return job
            }
            if job.isTerminal {
                throw OfflineMapPlatformError.serverStatus(
                    409,
                    job.error ?? "Map job ended with status \(job.status)"
                )
            }
            try await sleep(pollIntervalNanoseconds)
        }
        throw CancellationError()
    }
}

@MainActor
enum OfflineMapJobCreator {
    static func create(
        request: OfflineMapJobRequest,
        maximumAttempts: Int = 3,
        create: @escaping (OfflineMapJobRequest) async throws -> OfflineMapJob,
        list: @escaping () async throws -> [OfflineMapJob],
        sleep: @escaping (UInt64) async throws -> Void,
        onRetry: @escaping () -> Void
    ) async throws -> OfflineMapJob {
        precondition(maximumAttempts > 0)
        var lastError: Error?
        for attempt in 1...maximumAttempts {
            do {
                return try await create(request)
            } catch {
                guard OfflineMapPollingRetryPolicy.shouldRetry(error) else { throw error }
                lastError = error
            }

            do {
                if let recovered = try await list().first(where: { job in
                    job.clientInstallationId == request.clientInstallationId &&
                        job.clientRequestId == request.clientRequestId
                }) {
                    return recovered
                }
            } catch {
                guard OfflineMapPollingRetryPolicy.shouldRetry(error) else { throw error }
                lastError = error
            }

            if attempt < maximumAttempts {
                onRetry()
                try await sleep(
                    OfflineMapPollingRetryPolicy.delayNanoseconds(failureCount: attempt)
                )
            }
        }
        throw lastError ?? OfflineMapPlatformError.invalidResponse
    }
}

nonisolated enum OfflineMapJobPersistence {
    private static let activeJobIdKey = "offlineMap.activeJobId"
    private static let installOnDeviceKey = "offlineMap.activeJobInstallOnDevice"
    private static let serverURLKey = "offlineMap.activeJobServerURL"
    private static let apiTokenKey = "offlineMap.activeJobAPIToken"
    private static let downloadedJobIdKey = "offlineMap.activeJobDownloadedJobId"
    private static let downloadedMapIdKey = "offlineMap.activeJobDownloadedMapId"

    static func activeJobId(defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: activeJobIdKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func shouldInstallOnDevice(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: installOnDeviceKey)
    }

    static func serverURLString(defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: serverURLKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func downloadedJobId(defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: downloadedJobIdKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func downloadedMapId(defaults: UserDefaults) -> String? {
        guard let value = defaults.string(forKey: downloadedMapIdKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    static func apiTokenString(defaults: UserDefaults) -> String? {
        guard defaults.object(forKey: apiTokenKey) != nil else { return nil }
        return defaults.string(forKey: apiTokenKey) ?? ""
    }

    static func save(
        jobId: String,
        installOnDevice: Bool = false,
        serverURLString: String? = nil,
        apiTokenString: String? = nil,
        defaults: UserDefaults
    ) {
        defaults.set(jobId, forKey: activeJobIdKey)
        defaults.set(installOnDevice, forKey: installOnDeviceKey)
        if downloadedJobId(defaults: defaults) != jobId {
            defaults.removeObject(forKey: downloadedJobIdKey)
            defaults.removeObject(forKey: downloadedMapIdKey)
        }
        if let serverURLString, !serverURLString.isEmpty {
            defaults.set(serverURLString, forKey: serverURLKey)
        }
        if let apiTokenString {
            defaults.set(apiTokenString, forKey: apiTokenKey)
        }
    }

    static func markPackDownloaded(
        jobId: String,
        mapId: String,
        defaults: UserDefaults
    ) {
        guard activeJobId(defaults: defaults) == jobId else { return }
        defaults.set(jobId, forKey: downloadedJobIdKey)
        defaults.set(mapId, forKey: downloadedMapIdKey)
    }

    static func clear(defaults: UserDefaults) {
        defaults.removeObject(forKey: activeJobIdKey)
        defaults.removeObject(forKey: installOnDeviceKey)
        defaults.removeObject(forKey: serverURLKey)
        defaults.removeObject(forKey: apiTokenKey)
        defaults.removeObject(forKey: downloadedJobIdKey)
        defaults.removeObject(forKey: downloadedMapIdKey)
    }
}

nonisolated enum OfflineMapInstallationIdentity {
    private static let key = "offlineMap.clientInstallationId"

    static func resolve(defaults: UserDefaults) -> String {
        if let existing = defaults.string(forKey: key),
           existing.range(of: "^[A-Za-z0-9_-]{8,128}$", options: .regularExpression) != nil {
            return existing
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }
}

nonisolated enum OfflineMapRecoveryHistory {
    private static let key = "offlineMap.handledServerJobIds"
    private static let forgottenDiscoveryServersKey = "offlineMap.forgottenDiscoveryServers"
    private static let maximumCount = 1_000

    static func handledJobIds(defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    static func markHandled(jobId: String, defaults: UserDefaults) {
        markHandled(jobIds: [jobId], defaults: defaults)
    }

    static func markHandled(jobIds: [String], defaults: UserDefaults) {
        var values = defaults.stringArray(forKey: key) ?? []
        let additions = Set(jobIds)
        values.removeAll { additions.contains($0) }
        values.append(contentsOf: jobIds)
        defaults.set(Array(values.suffix(maximumCount)), forKey: key)
    }

    static func forgetNextDiscovery(serverURLString: String, defaults: UserDefaults) {
        var servers = Set(defaults.stringArray(forKey: forgottenDiscoveryServersKey) ?? [])
        servers.insert(serverIdentity(serverURLString))
        defaults.set(Array(servers).sorted(), forKey: forgottenDiscoveryServersKey)
    }

    static func shouldForgetNextDiscovery(
        serverURLString: String,
        defaults: UserDefaults
    ) -> Bool {
        let servers = Set(defaults.stringArray(forKey: forgottenDiscoveryServersKey) ?? [])
        return servers.contains(serverIdentity(serverURLString))
    }

    static func consumeForgottenDiscovery(
        serverURLString: String,
        jobIds: [String],
        defaults: UserDefaults
    ) -> Bool {
        let identity = serverIdentity(serverURLString)
        var servers = Set(defaults.stringArray(forKey: forgottenDiscoveryServersKey) ?? [])
        guard servers.remove(identity) != nil else { return false }
        markHandled(jobIds: jobIds, defaults: defaults)
        defaults.set(Array(servers).sorted(), forKey: forgottenDiscoveryServersKey)
        return true
    }

    private static func serverIdentity(_ value: String) -> String {
        OfflineMapServerIdentity.recoveryKey(value)
    }
}

nonisolated enum OfflineMapDownloadResponseValidator {
    static func validate(response: URLResponse?, errorBody: @autoclosure () -> String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OfflineMapPlatformError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw OfflineMapPlatformError.serverStatus(http.statusCode, errorBody())
        }
    }
}

@MainActor
final class OfflineMapManager: ObservableObject {
    typealias PackDownloadOperation = (
        URL,
        @escaping @MainActor @Sendable (Double) -> Void,
        @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void
    ) async throws -> URL

    @Published var serverURLString: String {
        didSet { defaults.set(serverURLString, forKey: OfflineMapDefaults.serverURLKey) }
    }
    @Published var apiToken: String {
        didSet { defaults.set(apiToken, forKey: OfflineMapDefaults.apiTokenKey) }
    }
    @Published var centerLatitude: String {
        didSet { defaults.set(centerLatitude, forKey: OfflineMapDefaults.centerLatitudeKey) }
    }
    @Published var centerLongitude: String {
        didSet { defaults.set(centerLongitude, forKey: OfflineMapDefaults.centerLongitudeKey) }
    }
    @Published var sideLengthKm: String {
        didSet { defaults.set(sideLengthKm, forKey: OfflineMapDefaults.sideLengthKey) }
    }
    @Published private(set) var currentJob: OfflineMapJob?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var downloadedPackURL: URL?
    @Published private(set) var cachedPackURLs: [URL] = []
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadByteProgress: OfflineMapByteProgress?
    @Published private(set) var transferProgress: Double = 0
    @Published private(set) var isBusy = false
    @Published private(set) var isServerRecoveryCheckPending = false
    @Published private(set) var isMapAreaSelectionActive = false
    @Published private(set) var selectedMapBounds: OfflineMapBounds?
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastTransferMapId: String
    @Published private(set) var lastTransferOutcome: String

    var activityProgress: Double? {
        OfflineMapProgressPresentation.value(
            job: currentJob,
            downloadProgress: downloadProgress
        )
    }

    var hasPendingMapJob: Bool {
        OfflineMapJobPersistence.activeJobId(defaults: defaults) != nil ||
            isServerRecoveryCheckPending
    }

    var hasDownloadedPendingDeviceInstall: Bool {
        guard OfflineMapJobPersistence.shouldInstallOnDevice(defaults: defaults),
              let activeJobId = OfflineMapJobPersistence.activeJobId(defaults: defaults),
              OfflineMapJobPersistence.downloadedJobId(defaults: defaults) == activeJobId,
              let mapId = OfflineMapJobPersistence.downloadedMapId(defaults: defaults),
              let cachedURL = try? cachedPackURL(mapId: mapId) else {
            return false
        }
        return FileManager.default.fileExists(atPath: cachedURL.path)
    }

    private let defaults: UserDefaults
    private let mapPlatformSession: URLSession
    private let packDownload: PackDownloadOperation
    private let cacheDirectoryOverride: URL?
    let clientInstallationId: String
    private let deviceTransferManager = DeviceTransferManager()
    @Published private var packDisplayNames: [String: String]
    private var mapJobTask: Task<Void, Never>?
    private var mapJobTaskID: UUID?

    init(
        defaults: UserDefaults = .standard,
        mapPlatformSession: URLSession = .shared,
        cacheDirectory: URL? = nil,
        packDownload: @escaping PackDownloadOperation = { url, onProgress, onByteProgress in
            try await OfflineMapPackDownloader.download(
                from: url,
                onProgress: onProgress,
                onByteProgress: onByteProgress
            )
        }
    ) {
        self.defaults = defaults
        self.mapPlatformSession = mapPlatformSession
        self.packDownload = packDownload
        self.cacheDirectoryOverride = cacheDirectory
        self.clientInstallationId = OfflineMapInstallationIdentity.resolve(defaults: defaults)
        self.packDisplayNames = defaults.dictionary(forKey: OfflineMapDefaults.packDisplayNamesKey) as? [String: String] ?? [:]
        self.serverURLString = Self.resolvedServerURL(defaults: defaults)
        self.apiToken = Self.resolvedAPIToken(defaults: defaults)
        self.centerLatitude = defaults.string(forKey: OfflineMapDefaults.centerLatitudeKey) ?? "35.16755"
        self.centerLongitude = defaults.string(forKey: OfflineMapDefaults.centerLongitudeKey) ?? "136.89451"
        self.sideLengthKm = defaults.string(forKey: OfflineMapDefaults.sideLengthKey) ?? "25"
        self.lastTransferMapId = defaults.string(forKey: OfflineMapDefaults.lastTransferMapIdKey) ?? ""
        let restoredTransferOutcome = defaults.string(
            forKey: OfflineMapDefaults.lastTransferOutcomeKey
        ) ?? ""
        if ["preparing", "uploading", "activating"].contains(restoredTransferOutcome) {
            self.lastTransferOutcome = "unconfirmed"
        } else {
            self.lastTransferOutcome = restoredTransferOutcome
        }
        defaults.set(serverURLString, forKey: OfflineMapDefaults.serverURLKey)
        defaults.set(apiToken, forKey: OfflineMapDefaults.apiTokenKey)
        defaults.set(lastTransferOutcome, forKey: OfflineMapDefaults.lastTransferOutcomeKey)
        refreshCachedPacks()
    }

    func createCustomCutoutJob() {
        do {
            try createJobAndDownload(request: makeCustomBBoxRequest())
        } catch {
            errorMessage = diagnosticMessage(for: error)
        }
    }

    func beginMapAreaSelection() {
        guard canStartNewMapJob() else { return }
        errorMessage = nil
        selectedMapBounds = nil
        isMapAreaSelectionActive = true
    }

    func cancelMapAreaSelection() {
        isMapAreaSelectionActive = false
    }

    func updateMapAreaSelection(bounds: OfflineMapBounds) {
        selectedMapBounds = bounds
    }

    func createJobFromSelectedMapArea() {
        guard canStartNewMapJob() else { return }
        guard let selectedMapBounds else {
            errorMessage = OfflineMapPlatformError.invalidResponse.localizedDescription
            return
        }
        isMapAreaSelectionActive = false
        createJobAndDownload(request: .customBBox(selectedMapBounds))
    }

    func installCurrentLocationMap(location: CLLocation, bleManager: BLEManager) {
        guard canStartNewMapJob() else { return }
        centerLatitude = String(format: "%.6f", location.coordinate.latitude)
        centerLongitude = String(format: "%.6f", location.coordinate.longitude)

        startMapJobTask { manager in
            let client = try manager.makeClient()
            if try await manager.recoverOwnedServerJobIfAvailable(
                client: client,
                bleManager: bleManager
            ) {
                return
            }
            let request = OfflineMapJobRequest
                .customBBox(OfflineMapBounds(
                    center: location.coordinate,
                    sideLengthKm: Double(manager.sideLengthKm) ?? 25
                ))
                .identified(
                    clientInstallationId: manager.clientInstallationId,
                    clientRequestId: UUID().uuidString.lowercased(),
                    installOnDevice: true
                )
            manager.currentJob = try await manager.createJob(request, client: client)
            manager.persistCurrentJob(installOnDevice: true)
            manager.downloadURL = nil
            manager.downloadedPackURL = nil
            manager.downloadProgress = 0
            manager.downloadByteProgress = nil
            manager.transferProgress = 0
            manager.statusMessage = "creating map"

            try await manager.waitForReadyMap(client: client)
            try await manager.downloadReadyPack(client: client)
            try await manager.transferReadyPack(bleManager: bleManager)
            manager.clearPersistedJob(markHandled: true)
        }
    }

    func resumePendingMapJobIfNeeded(bleManager: BLEManager? = nil) {
        guard mapJobTask == nil, !isBusy else {
            return
        }
        let persistedJobId = OfflineMapJobPersistence.activeJobId(defaults: defaults)
        let persistedInstallIntent = OfflineMapJobPersistence.shouldInstallOnDevice(defaults: defaults)
        let persistedServerURL = OfflineMapJobPersistence.serverURLString(defaults: defaults)
        let persistedAPIToken = OfflineMapJobPersistence.apiTokenString(defaults: defaults)
        if persistedJobId == nil {
            isServerRecoveryCheckPending = true
        }

        startMapJobTask { manager in
            let recoveryConnection = manager.recoveryConnection(
                persistedServerURL: persistedServerURL,
                persistedAPIToken: persistedAPIToken
            )
            let recoveryServerURL = recoveryConnection.serverURL
            let recoveryAPIToken = recoveryConnection.apiToken
            let client = try manager.makeClient(
                serverURLString: recoveryServerURL,
                apiTokenString: recoveryAPIToken
            )
            var jobId = persistedJobId
            var shouldInstallOnDevice = persistedInstallIntent

            if jobId == nil {
                manager.statusMessage = "checking for server maps"
                let jobs = try await manager.listJobsWithRetry(client: client)
                if manager.consumeForgottenDiscovery(
                    jobs: jobs,
                    serverURLString: recoveryServerURL
                ) {
                    manager.isServerRecoveryCheckPending = false
                    manager.statusMessage = ""
                    return
                }
                guard let recovered = manager.selectOwnedRecoverableJob(from: jobs) else {
                    manager.isServerRecoveryCheckPending = false
                    manager.statusMessage = ""
                    return
                }
                manager.adoptRecoveredJob(recovered)
                jobId = recovered.jobId
                shouldInstallOnDevice = recovered.installOnDevice == true
                manager.persistCurrentJob(installOnDevice: shouldInstallOnDevice)
                manager.isServerRecoveryCheckPending = false
            }

            guard let jobId else { return }
            try await manager.finishRecoveredJob(
                jobId: jobId,
                installOnDevice: shouldInstallOnDevice,
                client: client,
                bleManager: bleManager
            )
        }
    }

    func pausePendingMapJob() {
        guard mapJobTask != nil else { return }
        mapJobTask?.cancel()
        statusMessage = "map preparation paused"
    }

    func forgetPendingMapJob() {
        guard hasPendingMapJob else { return }
        if OfflineMapJobPersistence.activeJobId(defaults: defaults) == nil,
           isServerRecoveryCheckPending {
            OfflineMapRecoveryHistory.forgetNextDiscovery(
                serverURLString: serverURLString,
                defaults: defaults
            )
        }
        mapJobTask?.cancel()
        mapJobTask = nil
        mapJobTaskID = nil
        clearPersistedJob(markHandled: true)
        currentJob = nil
        downloadURL = nil
        downloadProgress = 0
        downloadByteProgress = nil
        transferProgress = 0
        statusMessage = "pending map forgotten"
        errorMessage = nil
    }

    func refreshJob() {
        guard let jobId = currentJob?.jobId else { return }
        Task {
            await runBusy {
                let client = try self.makeClient()
                self.currentJob = try await client.job(id: jobId)
                self.statusMessage = self.currentJob?.status ?? ""
                if self.currentJob?.mapId == nil {
                    self.downloadURL = nil
                    self.downloadedPackURL = nil
                    self.downloadProgress = 0
                    self.downloadByteProgress = nil
                    self.transferProgress = 0
                }
            }
        }
    }

    func fetchDownloadURL() {
        guard let mapId = currentJob?.mapId,
              let jobId = currentJob?.jobId else {
            errorMessage = OfflineMapPlatformError.missingMapId.localizedDescription
            return
        }
        Task {
            await runBusy {
                let client = try self.makeClient()
                self.downloadURL = try await client.downloadURL(mapId: mapId, jobId: jobId)
                self.statusMessage = "download ready"
            }
        }
    }

    func downloadPack() {
        Task {
            await runBusy {
                try await self.downloadReadyPack(client: self.makeClient())
            }
        }
    }

    func transferDownloadedPack(bleManager: BLEManager) {
        Task {
            await runBusy {
                guard let packURL = self.downloadedPackURL else {
                    throw OfflineMapPlatformError.missingDownloadURL
                }
                try await self.transferPack(at: packURL, bleManager: bleManager)
            }
        }
    }

    func transferCachedPack(at packURL: URL, bleManager: BLEManager) {
        Task {
            await runBusy {
                try await self.transferPack(at: packURL, bleManager: bleManager)
            }
        }
    }

    func deleteCachedPack(at packURL: URL) {
        do {
            if FileManager.default.fileExists(atPath: packURL.path) {
                try FileManager.default.removeItem(at: packURL)
            }
            packDisplayNames.removeValue(forKey: packURL.lastPathComponent)
            persistPackDisplayNames()
            if downloadedPackURL == packURL {
                downloadedPackURL = nil
                transferProgress = 0
            }
            refreshCachedPacks()
        } catch {
            errorMessage = diagnosticMessage(for: error)
        }
    }

    func displayName(forCachedPack packURL: URL) -> String {
        if let displayName = packDisplayNames[packURL.lastPathComponent], !displayName.isEmpty {
            return displayName
        }
        if currentJob?.mapId == packURL.deletingPathExtension().lastPathComponent,
           let displayName = displayNameForCurrentJob() {
            return displayName
        }
        return packURL.deletingPathExtension().lastPathComponent
    }

    @discardableResult
    func renameCachedPack(at packURL: URL, to proposedName: String) -> String {
        let displayName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            return self.displayName(forCachedPack: packURL)
        }
        packDisplayNames[packURL.lastPathComponent] = displayName
        persistPackDisplayNames()
        return displayName
    }

    func isCachedPackInstalled(_ packURL: URL,
                               activeMapId: String,
                               activeSessionId: String) -> Bool {
        guard !activeMapId.isEmpty,
              activeMapId == packURL.deletingPathExtension().lastPathComponent else {
            return false
        }
        // Older firmware exposes only mapId. New firmware includes the durable
        // content-derived session so regenerated same-area packs are not shown
        // as installed merely because their stable map IDs match.
        guard !activeSessionId.isEmpty else { return true }
        guard let archive = try? OfflineMapPackArchive(url: packURL),
              let manifest = try? archive.manifest(),
              let mapId = manifest.mapId,
              let manifestEntry = archive.manifestEntry,
              let manifestData = try? archive.data(for: manifestEntry) else {
            return false
        }
        return MapTransferSessionIdentity.make(
            mapId: mapId,
            manifestData: manifestData
        ) == activeSessionId
    }

    var lastTransferDescription: String? {
        guard !lastTransferMapId.isEmpty else { return nil }
        let outcome = lastTransferOutcome.isEmpty ? "unknown" : lastTransferOutcome
        return "\(displayName(forMapId: lastTransferMapId)) — \(outcome)"
    }

    func displayName(forMapId mapId: String) -> String {
        let filename = "\(mapId).zip"
        if let displayName = packDisplayNames[filename], !displayName.isEmpty {
            return displayName
        }
        return mapId
    }

    func reconcileLastTransfer(bleManager: BLEManager) {
        guard lastTransferOutcome == "unconfirmed",
              !lastTransferMapId.isEmpty,
              let sessionId = defaults.string(
                forKey: OfflineMapDefaults.lastTransferSessionIdKey
              ),
              !sessionId.isEmpty else {
            return
        }

        let previousMapId = defaults.string(
            forKey: OfflineMapDefaults.lastTransferPreviousMapIdKey
        )
        let previousSessionId = defaults.string(
            forKey: OfflineMapDefaults.lastTransferPreviousSessionIdKey
        )
        let previousSequence = (
            defaults.object(forKey: OfflineMapDefaults.lastTransferPreviousSequenceKey)
                as? NSNumber
        )?.uint32Value
        let acceptedSequence = (
            defaults.object(forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey)
                as? NSNumber
        )?.uint32Value
        let evaluation = MapActivationReconciler.evaluate(
            expectedMapId: lastTransferMapId,
            sessionId: sessionId,
            previousMapId: previousMapId,
            previousSessionId: previousSessionId,
            previousSequence: previousSequence,
            acceptedSequence: acceptedSequence,
            observedCurrentAttempt: false,
            activeMapId: bleManager.mapTransferActiveMapId,
            activeSessionId: bleManager.mapTransferActiveSessionId,
            activationStatus: bleManager.mapTransferActivationStatus,
            activationSequence: bleManager.mapTransferActivationSequence,
            activationSessionId: bleManager.mapTransferActivationSessionId,
            activationMapId: bleManager.mapTransferActivationMapId,
            activationError: bleManager.mapTransferActivationError ??
                bleManager.mapTransferLastError
        )
        switch evaluation.decision {
        case .installed:
            updateLastTransferOutcome("installed")
        case .failed:
            updateLastTransferOutcome("failed")
        case .pending:
            break
        }
    }

    func makeCustomBBoxRequest() throws -> OfflineMapJobRequest {
        guard let latitude = Double(centerLatitude),
              let longitude = Double(centerLongitude),
              let sizeKm = Double(sideLengthKm) else {
            throw OfflineMapPlatformError.invalidResponse
        }
        let bounds = OfflineMapBounds(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            sideLengthKm: sizeKm
        )
        return .customBBox(bounds)
    }

    private func createJobAndDownload(request: OfflineMapJobRequest) {
        guard canStartNewMapJob() else { return }
        startMapJobTask { manager in
            let client = try manager.makeClient()
            if try await manager.recoverOwnedServerJobIfAvailable(
                client: client,
                bleManager: nil
            ) {
                return
            }
            manager.currentJob = nil
            manager.downloadURL = nil
            manager.downloadedPackURL = nil
            manager.downloadProgress = 0
            manager.downloadByteProgress = nil
            manager.transferProgress = 0
            manager.statusMessage = "creating map job"

            let identifiedRequest = request.identified(
                clientInstallationId: manager.clientInstallationId,
                clientRequestId: UUID().uuidString.lowercased(),
                installOnDevice: false
            )
            manager.currentJob = try await manager.createJob(identifiedRequest, client: client)
            manager.persistCurrentJob(installOnDevice: false)
            manager.statusMessage = manager.currentJob?.status ?? ""
            try await manager.waitForReadyMap(client: client)
            try await manager.downloadReadyPack(client: client)
            manager.clearPersistedJob(markHandled: true)
        }
    }

    private func startMapJobTask(
        _ operation: @MainActor @escaping (OfflineMapManager) async throws -> Void
    ) {
        guard mapJobTask == nil else { return }
        let taskID = UUID()
        mapJobTaskID = taskID
        mapJobTask = Task { [weak self] in
            guard let self else { return }
            await runBusy {
                try await operation(self)
            }
            if mapJobTaskID == taskID {
                mapJobTask = nil
                mapJobTaskID = nil
            }
        }
    }

    private func createJob(
        _ request: OfflineMapJobRequest,
        client: OfflineMapPlatformClient
    ) async throws -> OfflineMapJob {
        try await OfflineMapJobCreator.create(
            request: request,
            create: { identifiedRequest in
                try await client.createJob(identifiedRequest)
            },
            list: {
                try await client.jobs()
            },
            sleep: { nanoseconds in
                try await Task.sleep(nanoseconds: nanoseconds)
            },
            onRetry: { [weak self] in
                self?.statusMessage = "reconnecting to map server"
            }
        )
    }

    private func listJobsWithRetry(
        client: OfflineMapPlatformClient
    ) async throws -> [OfflineMapJob] {
        var failureCount = 0
        while !Task.isCancelled {
            do {
                return try await client.jobs()
            } catch {
                guard OfflineMapPollingRetryPolicy.shouldRetry(error) else { throw error }
                failureCount += 1
                statusMessage = "reconnecting to map server"
                try await Task.sleep(
                    nanoseconds: OfflineMapPollingRetryPolicy.delayNanoseconds(
                        failureCount: failureCount
                    )
                )
            }
        }
        throw CancellationError()
    }

    private func selectOwnedRecoverableJob(from jobs: [OfflineMapJob]) -> OfflineMapJob? {
        OfflineMapJobRecoverySelector.select(
            jobs: jobs,
            clientInstallationId: clientInstallationId,
            excludedJobIds: OfflineMapRecoveryHistory.handledJobIds(defaults: defaults)
        )
    }

    private func consumeForgottenDiscovery(
        jobs: [OfflineMapJob],
        serverURLString: String
    ) -> Bool {
        OfflineMapRecoveryHistory.consumeForgottenDiscovery(
            serverURLString: serverURLString,
            jobIds: jobs
                .filter { $0.clientInstallationId == clientInstallationId }
                .map(\.jobId),
            defaults: defaults
        )
    }

    private func recoverOwnedServerJobIfAvailable(
        client: OfflineMapPlatformClient,
        bleManager: BLEManager?
    ) async throws -> Bool {
        let jobs = try await client.jobs()
        if consumeForgottenDiscovery(
            jobs: jobs,
            serverURLString: client.baseURL.absoluteString
        ) {
            return false
        }
        guard let recovered = selectOwnedRecoverableJob(from: jobs) else { return false }
        adoptRecoveredJob(recovered)
        let installOnDevice = recovered.installOnDevice == true
        persistCurrentJob(installOnDevice: installOnDevice)
        statusMessage = "resuming previous map"
        try await finishRecoveredJob(
            jobId: recovered.jobId,
            installOnDevice: installOnDevice,
            client: client,
            bleManager: bleManager
        )
        return true
    }

    private func makeClient(
        serverURLString: String? = nil,
        apiTokenString: String? = nil
    ) throws -> OfflineMapPlatformClient {
        let value = serverURLString ?? self.serverURLString
        guard let url = URL(string: value), url.scheme != nil else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        return OfflineMapPlatformClient(
            baseURL: url,
            apiToken: apiTokenString ?? apiToken,
            clientInstallationId: clientInstallationId,
            session: mapPlatformSession
        )
    }

    private func recoveryConnection(
        persistedServerURL: String?,
        persistedAPIToken: String?
    ) -> (serverURL: String, apiToken: String?) {
        guard let persistedServerURL,
              !persistedServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (serverURLString, apiToken)
        }
        if OfflineMapServerIdentity.isManaged(persistedServerURL) {
            let bundledToken = OfflineMapServiceConfig.apiToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let managedToken = bundledToken.isEmpty &&
                OfflineMapServerIdentity.isManaged(serverURLString) ? apiToken : bundledToken
            return (OfflineMapServiceConfig.productionServerURLString, managedToken)
        }
        if OfflineMapServerIdentity.normalized(persistedServerURL) ==
            OfflineMapServerIdentity.normalized(serverURLString) {
            return (serverURLString, apiToken)
        }
        return (persistedServerURL, persistedAPIToken)
    }

    private func adoptRecoveredJob(_ job: OfflineMapJob) {
        if currentJob?.jobId != job.jobId {
            downloadedPackURL = nil
            downloadProgress = 0
            downloadByteProgress = nil
            transferProgress = 0
        }
        currentJob = job
        downloadURL = nil
    }

    nonisolated static func resolvedServerURL(defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: OfflineMapDefaults.serverURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if OfflineMapServerIdentity.isManaged(stored) {
            return OfflineMapServiceConfig.productionServerURLString
        }
        return stored
    }

    nonisolated static func resolvedAPIToken(
        defaults: UserDefaults,
        bundledToken: String = OfflineMapServiceConfig.apiToken
    ) -> String {
        let bundled = bundledToken
        let stored = defaults.string(forKey: OfflineMapDefaults.apiTokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storedServer = defaults.string(forKey: OfflineMapDefaults.serverURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usesBundledServer = OfflineMapServerIdentity.isManaged(storedServer)
        if usesBundledServer, !bundled.isEmpty {
            return bundled
        }
        return stored
    }

    private func readyMapId() throws -> String {
        guard let mapId = currentJob?.mapId else {
            throw OfflineMapPlatformError.missingMapId
        }
        return mapId
    }

    private func waitForReadyMap(
        client: OfflineMapPlatformClient,
        jobId explicitJobId: String? = nil
    ) async throws {
        guard let jobId = explicitJobId ?? currentJob?.jobId else {
            throw OfflineMapPlatformError.invalidResponse
        }

        do {
            currentJob = try await OfflineMapJobPoller.waitForReady(
                jobId: jobId,
                pollIntervalNanoseconds: OfflineMapDefaults.mapJobPollIntervalNanoseconds,
                fetch: { id in try await client.job(id: id) },
                sleep: { nanoseconds in try await Task.sleep(nanoseconds: nanoseconds) },
                onUpdate: { [weak self] job in
                    self?.currentJob = job
                    self?.statusMessage = job.status
                },
                onRetry: { [weak self] in
                    self?.statusMessage = "reconnecting to map server"
                }
            )
        } catch {
            if currentJob?.isTerminal == true || shouldForgetPersistedJob(after: error) {
                clearPersistedJob()
            }
            throw error
        }
    }

    private func downloadReadyPack(client: OfflineMapPlatformClient) async throws {
        let mapId = try readyMapId()
        guard let jobId = currentJob?.jobId else {
            throw OfflineMapPlatformError.invalidResponse
        }
        let url = try await client.downloadURL(mapId: mapId, jobId: jobId)
        downloadURL = url

        statusMessage = "downloading pack"
        downloadProgress = 0
        downloadByteProgress = nil
        var temporaryURL: URL?
        do {
            let downloadedURL = try await packDownload(url, { [weak self] progress in
                self?.downloadProgress = progress
            }, { [weak self] byteProgress in
                self?.downloadByteProgress = byteProgress
            })
            temporaryURL = downloadedURL
            try await Task.detached(priority: .userInitiated) {
                let archive = try OfflineMapPackArchive(url: downloadedURL)
                try archive.validate(expectedMapId: mapId)
            }.value
        } catch {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            downloadURL = nil
            throw error
        }
        guard let temporaryURL else {
            downloadURL = nil
            throw OfflineMapPlatformError.missingDownloadURL
        }
        let destination = try cachedPackURL(mapId: mapId)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            downloadURL = nil
            throw error
        }
        downloadedPackURL = destination
        if let jobId = currentJob?.jobId {
            OfflineMapJobPersistence.markPackDownloaded(
                jobId: jobId,
                mapId: mapId,
                defaults: defaults
            )
        }
        if packDisplayNames[destination.lastPathComponent]?.isEmpty != false,
           let displayName = displayNameForCurrentJob() {
            packDisplayNames[destination.lastPathComponent] = displayName
            persistPackDisplayNames()
        }
        refreshCachedPacks()
        downloadProgress = 1
        downloadByteProgress = nil
        transferProgress = 0
        statusMessage = "pack downloaded"
    }

    private func finishRecoveredJob(
        jobId: String,
        installOnDevice: Bool,
        client: OfflineMapPlatformClient,
        bleManager: BLEManager?
    ) async throws {
        if installOnDevice, restoreDownloadedPackIfAvailable(jobId: jobId) {
            guard let bleManager,
                  bleManager.isConnected,
                  bleManager.isNavigationReady else {
                statusMessage = "map downloaded; reconnect device to install"
                return
            }
            try await transferReadyPack(bleManager: bleManager)
            clearPersistedJob(markHandled: true)
            return
        }

        try await waitForReadyMap(client: client, jobId: jobId)
        let canReuseDownloadedPack = OfflineMapJobPersistence.downloadedJobId(
            defaults: defaults
        ) == jobId
        if canReuseDownloadedPack,
           let mapId = currentJob?.mapId {
            let cachedURL = try cachedPackURL(mapId: mapId)
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                downloadedPackURL = cachedURL
                downloadProgress = 1
                statusMessage = "pack downloaded"
            } else {
                try await downloadReadyPack(client: client)
            }
        } else {
            try await downloadReadyPack(client: client)
        }
        if installOnDevice {
            guard let bleManager,
                  bleManager.isConnected,
                  bleManager.isNavigationReady else {
                statusMessage = "map downloaded; reconnect device to install"
                return
            }
            try await transferReadyPack(bleManager: bleManager)
        }
        clearPersistedJob(markHandled: true)
    }

    private func restoreDownloadedPackIfAvailable(jobId: String) -> Bool {
        guard OfflineMapJobPersistence.downloadedJobId(defaults: defaults) == jobId,
              let mapId = OfflineMapJobPersistence.downloadedMapId(defaults: defaults),
              let cachedURL = try? cachedPackURL(mapId: mapId),
              FileManager.default.fileExists(atPath: cachedURL.path) else {
            return false
        }
        downloadedPackURL = cachedURL
        downloadProgress = 1
        downloadByteProgress = nil
        statusMessage = "pack downloaded"
        return true
    }

    private func persistCurrentJob(installOnDevice: Bool) {
        guard let jobId = currentJob?.jobId else { return }
        OfflineMapJobPersistence.save(
            jobId: jobId,
            installOnDevice: installOnDevice,
            serverURLString: serverURLString,
            apiTokenString: apiToken,
            defaults: defaults
        )
    }

    private func clearPersistedJob(markHandled: Bool = false) {
        if markHandled,
           let jobId = OfflineMapJobPersistence.activeJobId(defaults: defaults) {
            OfflineMapRecoveryHistory.markHandled(jobId: jobId, defaults: defaults)
        }
        OfflineMapJobPersistence.clear(defaults: defaults)
        isServerRecoveryCheckPending = false
    }

    private func canStartNewMapJob() -> Bool {
        guard !hasPendingMapJob else {
            errorMessage = "Resume the pending map before starting another download."
            return false
        }
        return true
    }

    private func shouldForgetPersistedJob(after error: Error) -> Bool {
        guard let platformError = error as? OfflineMapPlatformError,
              case .serverStatus(let status, _) = platformError else {
            return false
        }
        return status == 404
    }

    private func transferReadyPack(bleManager: BLEManager) async throws {
        guard let packURL = downloadedPackURL else {
            throw OfflineMapPlatformError.missingDownloadURL
        }
        try await transferPack(at: packURL, bleManager: bleManager)
    }

    private func transferPack(at packURL: URL, bleManager: BLEManager) async throws {
        statusMessage = "preparing transfer"
        transferProgress = 0
        let archive = try await Task.detached(priority: .userInitiated) {
            let archive = try OfflineMapPackArchive(url: packURL)
            guard let mapId = try archive.manifest().mapId, !mapId.isEmpty else {
                throw OfflineMapPlatformError.invalidPack("manifest.json has no mapId")
            }
            try archive.validate(expectedMapId: mapId)
            return archive
        }.value
        guard let expectedMapId = try archive.manifest().mapId,
              !expectedMapId.isEmpty else {
            throw OfflineMapPlatformError.invalidPack("manifest.json has no mapId")
        }
        guard let manifestEntry = archive.manifestEntry else {
            throw OfflineMapPlatformError.invalidPack("manifest.json is missing")
        }
        let manifestData = try archive.data(for: manifestEntry)
        let sessionId = MapTransferSessionIdentity.make(
            mapId: expectedMapId,
            manifestData: manifestData
        )
        recordTransfer(
            mapId: expectedMapId,
            sessionId: sessionId,
            previousMapId: bleManager.mapTransferActiveMapId,
            previousSessionId: bleManager.mapTransferActiveSessionId,
            previousSequence: bleManager.mapTransferActivationSequence,
            outcome: "preparing"
        )

        do {
            let transferSession = try await deviceTransferManager.enterMapTransfer(
                bleManager: bleManager
            ) { message in
                self.statusMessage = message
            }
            defer {
                deviceTransferManager.exitMapTransfer(bleManager: bleManager)
            }
            downloadedPackURL = packURL
            let client = MapTransferDeviceClient(
                baseURL: transferSession.baseURL,
                sessionToken: transferSession.sessionToken
            )
            transferProgress = 0
            statusMessage = "uploading \(displayName(forMapId: expectedMapId)) to device"
            updateLastTransferOutcome("uploading")
            do {
                try await client.uploadArchiveInBackground(
                    archiveURL: packURL,
                    sessionId: sessionId
                ) { completedBytes, totalBytes in
                    self.transferProgress = totalBytes == 0 ? 0 :
                        Double(completedBytes) / Double(totalBytes)
                    let percent = Int((self.transferProgress * 100).rounded())
                    self.statusMessage = "uploading \(self.displayName(forMapId: expectedMapId)): \(percent)%"
                }
                transferProgress = 1
                statusMessage = "map uploaded; activating on device"
            } catch OfflineMapPlatformError.serverStatus(let status, _) where status == 400 {
                statusMessage = "device uses foreground map transfer"
                try await client.upload(
                    archive: archive,
                    sessionId: sessionId
                ) { completed, total, path, didUpload in
                    self.transferProgress = total == 0 ? 0 : Double(completed) / Double(total)
                    let prefix = didUpload ? "uploaded" : "already on device"
                    self.statusMessage = "\(prefix) \(completed)/\(total): \(path)"
                }
            }

            let statusBeforeActivation = try? await client.status()
            let previousMapId = statusBeforeActivation?.activeMapId ?? bleManager.mapTransferActiveMapId
            let previousSessionId = statusBeforeActivation?.activeSessionId ??
                bleManager.mapTransferActiveSessionId
            let previousSequence = statusBeforeActivation?.activation?.sequence ??
                bleManager.mapTransferActivationSequence
            recordTransfer(
                mapId: expectedMapId,
                sessionId: sessionId,
                previousMapId: previousMapId,
                previousSessionId: previousSessionId,
                previousSequence: previousSequence,
                outcome: "activating"
            )
            statusMessage = "activating \(displayName(forMapId: expectedMapId))"
            bleManager.resetMapTransferActivationObservation()
            var acceptedSequence: UInt32? = nil
            do {
                acceptedSequence = try await client.activate(sessionId: sessionId)
                if let acceptedSequence {
                    defaults.set(
                        Int(acceptedSequence),
                        forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey
                    )
                }
            } catch {
                guard MapActivationTransport.isAmbiguousResponseError(error) else {
                    throw error
                }
            }

            try await confirmActivatedMap(
                expectedMapId: expectedMapId,
                sessionId: sessionId,
                previousMapId: previousMapId,
                previousSessionId: previousSessionId,
                previousSequence: previousSequence,
                acceptedSequence: acceptedSequence,
                client: client,
                bleManager: bleManager
            )
            transferProgress = 1
            statusMessage = "map installed: \(displayName(forMapId: expectedMapId))"
            updateLastTransferOutcome("installed")
            bleManager.requestMapTransferStatus()
        } catch {
            if let platformError = error as? OfflineMapPlatformError {
                switch platformError {
                case .mapActivationTimedOut:
                    updateLastTransferOutcome("unconfirmed")
                default:
                    updateLastTransferOutcome("failed")
                }
            } else {
                updateLastTransferOutcome("failed")
            }
            throw error
        }
    }

    func confirmActivatedMap(expectedMapId: String,
                             sessionId: String,
                             previousMapId: String?,
                             previousSessionId: String?,
                             previousSequence: UInt32?,
                             acceptedSequence: UInt32?,
                             client: MapTransferDeviceClient,
                             bleManager: BLEManager,
                             timeout: TimeInterval = OfflineMapDefaults.activationConfirmationTimeout,
                             pollIntervalNanoseconds: UInt64 = OfflineMapDefaults.activationPollIntervalNanoseconds) async throws {
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(timeout)
        var lastObservedState = "activation request accepted"
        var observedCurrentAttempt = false

        while Date() < deadline {
            var receivedHTTPStatus = false
            do {
                let status = try await client.status()
                receivedHTTPStatus = true
                let activation = status.activation
                let evaluation = MapActivationReconciler.evaluate(
                    expectedMapId: expectedMapId,
                    sessionId: sessionId,
                    previousMapId: previousMapId,
                    previousSessionId: previousSessionId,
                    previousSequence: previousSequence,
                    acceptedSequence: acceptedSequence,
                    observedCurrentAttempt: observedCurrentAttempt,
                    activeMapId: status.activeMapId,
                    activeSessionId: status.activeSessionId,
                    activationStatus: activation?.status,
                    activationSequence: activation?.sequence,
                    activationSessionId: activation?.sessionId,
                    activationMapId: activation?.mapId,
                    activationError: activation?.error?.message ?? activation?.error?.code
                )
                observedCurrentAttempt = evaluation.observedCurrentAttempt
                switch evaluation.decision {
                case .installed:
                    return
                case .failed(let message):
                    throw OfflineMapPlatformError.mapActivationFailed(message)
                case .pending(let state):
                    lastObservedState = state
                }
            } catch let error as OfflineMapPlatformError {
                if case .mapActivationFailed = error {
                    throw error
                }
                receivedHTTPStatus = false
                lastObservedState = "device Wi-Fi status unavailable: \(error.localizedDescription)"
            } catch {
                receivedHTTPStatus = false
                lastObservedState = "device Wi-Fi status unavailable"
            }

            if !receivedHTTPStatus {
                bleManager.requestMapTransferStatus()
                let evaluation = MapActivationReconciler.evaluate(
                    expectedMapId: expectedMapId,
                    sessionId: sessionId,
                    previousMapId: previousMapId,
                    previousSessionId: previousSessionId,
                    previousSequence: previousSequence,
                    acceptedSequence: acceptedSequence,
                    observedCurrentAttempt: observedCurrentAttempt,
                    activeMapId: bleManager.mapTransferActiveMapId,
                    activeSessionId: bleManager.mapTransferActiveSessionId,
                    activationStatus: bleManager.mapTransferActivationStatus,
                    activationSequence: bleManager.mapTransferActivationSequence,
                    activationSessionId: bleManager.mapTransferActivationSessionId,
                    activationMapId: bleManager.mapTransferActivationMapId,
                    activationError: bleManager.mapTransferActivationError ??
                        bleManager.mapTransferLastError
                )
                observedCurrentAttempt = evaluation.observedCurrentAttempt
                switch evaluation.decision {
                case .installed:
                    return
                case .failed(let message):
                    throw OfflineMapPlatformError.mapActivationFailed(message)
                case .pending(let state):
                    lastObservedState = state
                }
            }

            let elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
            statusMessage = "activating \(displayName(forMapId: expectedMapId)) (\(elapsedSeconds)s)"
            try await Task.sleep(
                nanoseconds: pollIntervalNanoseconds
            )
        }

        throw OfflineMapPlatformError.mapActivationTimedOut(
            "expected \(expectedMapId); last device state was \(lastObservedState)"
        )
    }

    private func recordTransfer(mapId: String,
                                sessionId: String,
                                previousMapId: String?,
                                previousSessionId: String?,
                                previousSequence: UInt32?,
                                outcome: String) {
        lastTransferMapId = mapId
        defaults.set(mapId, forKey: OfflineMapDefaults.lastTransferMapIdKey)
        defaults.set(sessionId, forKey: OfflineMapDefaults.lastTransferSessionIdKey)
        defaults.set(previousMapId ?? "", forKey: OfflineMapDefaults.lastTransferPreviousMapIdKey)
        defaults.set(previousSessionId ?? "", forKey: OfflineMapDefaults.lastTransferPreviousSessionIdKey)
        defaults.removeObject(forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey)
        if let previousSequence {
            defaults.set(Int(previousSequence), forKey: OfflineMapDefaults.lastTransferPreviousSequenceKey)
        } else {
            defaults.removeObject(forKey: OfflineMapDefaults.lastTransferPreviousSequenceKey)
        }
        updateLastTransferOutcome(outcome)
    }

    private func updateLastTransferOutcome(_ outcome: String) {
        lastTransferOutcome = outcome
        defaults.set(outcome, forKey: OfflineMapDefaults.lastTransferOutcomeKey)
    }

    private func displayNameForCurrentJob() -> String? {
        if let regionName = currentJob?.sourceRegion?.name.trimmingCharacters(in: .whitespacesAndNewlines),
           !regionName.isEmpty {
            return Self.cleanDisplayName(regionName)
        }
        if let mapId = currentJob?.mapId, !mapId.isEmpty {
            return mapId
        }
        return nil
    }

    private static func cleanDisplayName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-latest.osm.pbf", with: "")
            .replacingOccurrences(of: ".osm.pbf", with: "")
            .replacingOccurrences(of: ".zip", with: "")
            .replacingOccurrences(of: "geofabrik-", with: "")
    }

    private func persistPackDisplayNames() {
        defaults.set(packDisplayNames, forKey: OfflineMapDefaults.packDisplayNamesKey)
    }

    private func cachedPackURL(mapId: String) throws -> URL {
        let directory = try cachedPackDirectory()
        return directory.appendingPathComponent("\(mapId).zip")
    }

    private func cachedPackDirectory() throws -> URL {
        if let cacheDirectoryOverride {
            try FileManager.default.createDirectory(
                at: cacheDirectoryOverride,
                withIntermediateDirectories: true
            )
            return cacheDirectoryOverride
        }
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("OfflineMapPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func refreshCachedPacks() {
        do {
            let directory = try cachedPackDirectory()
            let packURLs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "zip" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
            cacheMissingDisplayNames(for: packURLs)
            cachedPackURLs = packURLs
        } catch {
            cachedPackURLs = []
        }
    }

    private func cacheMissingDisplayNames(for packURLs: [URL]) {
        var didChange = false
        for packURL in packURLs where packDisplayNames[packURL.lastPathComponent]?.isEmpty != false {
            guard let displayName = manifestDisplayName(for: packURL) else { continue }
            packDisplayNames[packURL.lastPathComponent] = displayName
            didChange = true
        }
        if didChange {
            persistPackDisplayNames()
        }
    }

    private func manifestDisplayName(for packURL: URL) -> String? {
        guard let archive = try? OfflineMapPackArchive(url: packURL),
              let manifest = try? archive.manifest() else {
            return nil
        }
        let candidates = [
            manifest.source?.url.flatMap { URL(string: $0)?.lastPathComponent },
            manifest.source?.region,
            manifest.displayName
        ]
        for candidate in candidates {
            guard let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  !value.hasPrefix("custom-map-") else {
                continue
            }
            return Self.cleanDisplayName(value)
        }
        return nil
    }

    private func runBusy(_ operation: @MainActor @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = diagnosticMessage(for: error)
        }
    }

    private func diagnosticMessage(for error: Error) -> String {
        if error is OfflineMapPlatformError {
            return error.localizedDescription
        }

        let nsError = error as NSError
        var parts = [error.localizedDescription]
        if nsError.domain != NSCocoaErrorDomain || nsError.code != 0 {
            parts.append("\(nsError.domain) \(nsError.code)")
        }
        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append(failingURL.absoluteString)
        }
        return parts.joined(separator: "\n")
    }
}

struct OfflineMapByteProgress: Equatable {
    let completedBytes: Int64
    let totalBytes: Int64
}

final class OfflineMapPackDownloader: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @MainActor @Sendable (Double) -> Void
    private let onByteProgress: @MainActor @Sendable (OfflineMapByteProgress) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    private init(
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void
    ) {
        self.onProgress = onProgress
        self.onByteProgress = onByteProgress
    }

    static func download(
        from url: URL,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void,
        configuration: URLSessionConfiguration = .default
    ) async throws -> URL {
        let downloader = OfflineMapPackDownloader(onProgress: onProgress, onByteProgress: onByteProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                configuration.timeoutIntervalForRequest = 120
                configuration.timeoutIntervalForResource = 60 * 60
                configuration.waitsForConnectivity = true
                let session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
                downloader.session = session
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            downloader.session?.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        let byteProgress = OfflineMapByteProgress(
            completedBytes: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        )
        Task { @MainActor [onProgress, onByteProgress] in
            onProgress(progress)
            onByteProgress(byteProgress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try OfflineMapDownloadResponseValidator.validate(
                response: downloadTask.response,
                errorBody: (try? String(contentsOf: location, encoding: .utf8)) ?? ""
            )
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("zip")
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            continuation?.resume(returning: temporaryURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error, continuation != nil {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.finishTasksAndInvalidate()
    }
}
