//
//  OfflineMapManager.swift
//  BikeComputer
//
//  Coordinates offline map platform requests from the settings UI.
//

import CoreLocation
import Combine
import Foundation
#if os(iOS)
import NetworkExtension
#endif

private enum OfflineMapDefaults {
    nonisolated static let serverURLKey = "offlineMap.serverURL"
    nonisolated static let apiTokenKey = "offlineMap.apiToken"
    nonisolated static let centerLatitudeKey = "offlineMap.centerLatitude"
    nonisolated static let centerLongitudeKey = "offlineMap.centerLongitude"
    nonisolated static let sideLengthKey = "offlineMap.sideLengthKm"
    nonisolated static let packDisplayNamesKey = "offlineMap.packDisplayNames"
    nonisolated static let mapJobPollAttempts = 1800
    nonisolated static let legacyServerURLs = [
        "http://rhi0maej6bwo33hn0im6h4lf.178.18.245.246.sslip.io"
    ]
}

@MainActor
final class OfflineMapManager: ObservableObject {
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
    @Published private(set) var isMapAreaSelectionActive = false
    @Published private(set) var selectedMapBounds: OfflineMapBounds?
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private var packDisplayNames: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.packDisplayNames = defaults.dictionary(forKey: OfflineMapDefaults.packDisplayNamesKey) as? [String: String] ?? [:]
        self.serverURLString = Self.resolvedServerURL(defaults: defaults)
        self.apiToken = Self.resolvedAPIToken(defaults: defaults)
        self.centerLatitude = defaults.string(forKey: OfflineMapDefaults.centerLatitudeKey) ?? "35.16755"
        self.centerLongitude = defaults.string(forKey: OfflineMapDefaults.centerLongitudeKey) ?? "136.89451"
        self.sideLengthKm = defaults.string(forKey: OfflineMapDefaults.sideLengthKey) ?? "25"
        defaults.set(serverURLString, forKey: OfflineMapDefaults.serverURLKey)
        defaults.set(apiToken, forKey: OfflineMapDefaults.apiTokenKey)
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
        guard let selectedMapBounds else {
            errorMessage = OfflineMapPlatformError.invalidResponse.localizedDescription
            return
        }
        isMapAreaSelectionActive = false
        createJobAndDownload(request: .customBBox(selectedMapBounds))
    }

    func installCurrentLocationMap(location: CLLocation, bleManager: BLEManager) {
        centerLatitude = String(format: "%.6f", location.coordinate.latitude)
        centerLongitude = String(format: "%.6f", location.coordinate.longitude)

        Task {
            await runBusy {
                let client = try self.makeClient()
                let request = OfflineMapJobRequest.customBBox(OfflineMapBounds(
                    center: location.coordinate,
                    sideLengthKm: Double(self.sideLengthKm) ?? 25
                ))
                self.currentJob = try await client.createJob(request)
                self.downloadURL = nil
                self.downloadedPackURL = nil
                self.downloadProgress = 0
                self.downloadByteProgress = nil
                self.transferProgress = 0
                self.statusMessage = "creating map"

                try await self.waitForReadyMap(client: client)
                try await self.downloadReadyPack(client: client)
                try await self.transferReadyPack(bleManager: bleManager)
            }
        }
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
        guard let mapId = currentJob?.mapId else {
            errorMessage = OfflineMapPlatformError.missingMapId.localizedDescription
            return
        }
        Task {
            await runBusy {
                let client = try self.makeClient()
                self.downloadURL = try await client.downloadURL(mapId: mapId)
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
        Task {
            await runBusy {
                let client = try self.makeClient()
                self.currentJob = nil
                self.downloadURL = nil
                self.downloadedPackURL = nil
                self.downloadProgress = 0
                self.downloadByteProgress = nil
                self.transferProgress = 0
                self.statusMessage = "creating map job"

                self.currentJob = try await client.createJob(request)
                self.statusMessage = self.currentJob?.status ?? ""
                try await self.waitForReadyMap(client: client)
                try await self.downloadReadyPack(client: client)
            }
        }
    }

    private func makeClient() throws -> OfflineMapPlatformClient {
        guard let url = URL(string: serverURLString), url.scheme != nil else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        return OfflineMapPlatformClient(baseURL: url, apiToken: apiToken)
    }

    nonisolated static func resolvedServerURL(defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: OfflineMapDefaults.serverURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stored.isEmpty || OfflineMapDefaults.legacyServerURLs.contains(stored) {
            return OfflineMapServiceConfig.productionServerURLString
        }
        return stored
    }

    nonisolated static func resolvedAPIToken(defaults: UserDefaults) -> String {
        let bundled = OfflineMapServiceConfig.apiToken
        let stored = defaults.string(forKey: OfflineMapDefaults.apiTokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stored.isEmpty, !bundled.isEmpty {
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

    private func waitForReadyMap(client: OfflineMapPlatformClient) async throws {
        guard let jobId = currentJob?.jobId else {
            throw OfflineMapPlatformError.invalidResponse
        }

        for _ in 0..<OfflineMapDefaults.mapJobPollAttempts {
            let job = try await client.job(id: jobId)
            currentJob = job
            statusMessage = job.status
            if job.status == "ready", job.mapId != nil {
                return
            }
            if job.isTerminal {
                throw OfflineMapPlatformError.serverStatus(409, job.error ?? "Map job ended with status \(job.status)")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        throw OfflineMapPlatformError.serverStatus(
            408,
            "Map job is still running. Larger areas can take a long time to prepare."
        )
    }

    private func downloadReadyPack(client: OfflineMapPlatformClient) async throws {
        let mapId = try readyMapId()
        let url: URL
        if let downloadURL {
            url = downloadURL
        } else {
            url = try await client.downloadURL(mapId: mapId)
            downloadURL = url
        }

        statusMessage = "downloading pack"
        downloadProgress = 0
        downloadByteProgress = nil
        let temporaryURL = try await OfflineMapPackDownloader.download(from: url) { [weak self] progress in
            self?.downloadProgress = progress
        } onByteProgress: { [weak self] byteProgress in
            self?.downloadByteProgress = byteProgress
        }
        let destination = try cachedPackURL(mapId: mapId)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        downloadedPackURL = destination
        if let displayName = displayNameForCurrentJob() {
            packDisplayNames[destination.lastPathComponent] = displayName
            persistPackDisplayNames()
        }
        refreshCachedPacks()
        downloadProgress = 1
        downloadByteProgress = nil
        transferProgress = 0
        statusMessage = "pack downloaded"
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
            try OfflineMapPackArchive(url: packURL)
        }.value
        let expectedMapId = try? archive.manifest().mapId
        statusMessage = "requesting device transfer mode"
        let baseURL = try await enableDeviceTransferMode(bleManager: bleManager)
        await joinDeviceTransferNetworkIfNeeded(bleManager: bleManager,
                                                baseURL: baseURL)
        defer {
            bleManager.requestMapTransferMode(enabled: false)
        }
        downloadedPackURL = packURL
        let sessionId = transferSessionId(for: expectedMapId)
        let client = MapTransferDeviceClient(baseURL: baseURL)
        transferProgress = 0
        statusMessage = "uploading to device"
        try await client.upload(archive: archive, sessionId: sessionId) { completed, total, path, didUpload in
            self.transferProgress = total == 0 ? 0 : Double(completed) / Double(total)
            let prefix = didUpload ? "uploaded" : "already on device"
            self.statusMessage = "\(prefix) \(completed)/\(total): \(path)"
        }
        statusMessage = "activating map"
        do {
            try await client.activate(sessionId: sessionId)
        } catch {
            if isActivationResponseLoss(error),
               try await confirmActivatedMap(expectedMapId: expectedMapId,
                                             client: client,
                                             bleManager: bleManager) {
                transferProgress = 1
                statusMessage = "map installed"
                bleManager.requestMapTransferStatus()
                return
            }
            throw error
        }
        guard try await confirmActivatedMap(expectedMapId: expectedMapId,
                                            client: client,
                                            bleManager: bleManager) else {
            throw OfflineMapPlatformError.mapActivationTimedOut
        }
        transferProgress = 1
        statusMessage = "map installed"
        bleManager.requestMapTransferStatus()
    }

    private func isActivationResponseLoss(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain &&
            nsError.code == NSURLErrorNetworkConnectionLost
    }

    private func transferSessionId(for mapId: String?) -> String {
        guard let mapId else {
            return UUID().uuidString.lowercased()
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let sanitized = mapId.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let value = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        if value.isEmpty {
            return UUID().uuidString.lowercased()
        }
        return String(value.prefix(72))
    }

    private func confirmActivatedMap(expectedMapId: String?,
                                     client: MapTransferDeviceClient,
                                     bleManager: BLEManager) async throws -> Bool {
        guard let expectedMapId, !expectedMapId.isEmpty else {
            return false
        }

        statusMessage = "checking installed map"
        for attempt in 0..<240 {
            if let status = try? await client.status() {
                if status.activeMapId == expectedMapId {
                    return true
                }
                if status.activation?.status == "failed" {
                    let message = status.activation?.error?.message ??
                        status.activation?.error?.code ??
                        "device reported activation failure"
                    throw OfflineMapPlatformError.mapActivationFailed(message)
                }
            }
            bleManager.requestMapTransferStatus()
            if bleManager.mapTransferActiveMapId == expectedMapId {
                return true
            }
            if attempt % 10 == 9 {
                statusMessage = "checking installed map"
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return bleManager.mapTransferActiveMapId == expectedMapId
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

    private func enableDeviceTransferMode(bleManager: BLEManager) async throws -> URL {
        guard bleManager.isNavigationReady else {
            throw OfflineMapPlatformError.missingTransferBaseURL
        }

        guard bleManager.requestMapTransferMode(enabled: true) else {
            throw OfflineMapPlatformError.missingTransferBaseURL
        }
        guard bleManager.requestMapTransferStatus() else {
            throw OfflineMapPlatformError.missingTransferBaseURL
        }
        guard await bleManager.waitForNavigationWritesToDrain(timeoutSeconds: 2) else {
            throw OfflineMapPlatformError.transferCommandNotSent
        }
        for attempt in 0..<32 {
            if bleManager.deviceHasSDCard == false {
                throw OfflineMapPlatformError.deviceSDCardUnavailable
            }
            if bleManager.mapTransferModeEnabled, let baseURL = bleManager.mapTransferBaseURL {
                return baseURL
            }
            if attempt % 4 == 3 {
                bleManager.requestMapTransferStatus()
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw OfflineMapPlatformError.missingTransferBaseURL
    }

    private func joinDeviceTransferNetworkIfNeeded(bleManager: BLEManager,
                                                   baseURL: URL) async {
        guard baseURL.host == "192.168.4.1",
              let ssid = bleManager.mapTransferAccessPointSSID,
              !ssid.isEmpty else {
            return
        }

#if os(iOS)
        statusMessage = "joining device Wi-Fi"
        let configuration = NEHotspotConfiguration(ssid: ssid)
        configuration.joinOnce = true

        do {
            try await withCheckedThrowingContinuation { continuation in
                NEHotspotConfigurationManager.shared.apply(configuration) { error in
                    if let error = error as NSError? {
                        let message = error.localizedDescription
                        if message.localizedCaseInsensitiveContains("already") {
                            continuation.resume()
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    continuation.resume()
                }
            }
        } catch {
            if await isDeviceTransferServerReachable(baseURL: baseURL) {
                return
            }
            statusMessage = "using device Wi-Fi"
            return
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if await isDeviceTransferServerReachable(baseURL: baseURL) {
            return
        }
        statusMessage = "using device Wi-Fi"
#endif
    }

    private func isDeviceTransferServerReachable(baseURL: URL) async -> Bool {
        let url = baseURL.appendingPathComponent("map-transfer/status")
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 3

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func runBusy(_ operation: @MainActor @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
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

private final class OfflineMapPackDownloader: NSObject, URLSessionDownloadDelegate {
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
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void
    ) async throws -> URL {
        let downloader = OfflineMapPackDownloader(onProgress: onProgress, onByteProgress: onByteProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                let configuration = URLSessionConfiguration.default
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
