//
//  OfflineMapManager.swift
//  BikeComputer
//
//  Coordinates offline map platform requests from the settings UI.
//

import CoreLocation
import Combine
import Foundation

@MainActor
final class OfflineMapManager: ObservableObject {
    @Published var serverURLString: String {
        didSet { defaults.set(serverURLString, forKey: Self.serverURLKey) }
    }
    @Published var apiToken: String {
        didSet { defaults.set(apiToken, forKey: Self.apiTokenKey) }
    }
    @Published var centerLatitude: String {
        didSet { defaults.set(centerLatitude, forKey: Self.centerLatitudeKey) }
    }
    @Published var centerLongitude: String {
        didSet { defaults.set(centerLongitude, forKey: Self.centerLongitudeKey) }
    }
    @Published var sideLengthKm: String {
        didSet { defaults.set(sideLengthKm, forKey: Self.sideLengthKey) }
    }
    @Published private(set) var currentJob: OfflineMapJob?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var downloadedPackURL: URL?
    @Published private(set) var transferProgress: Double = 0
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?

    private static let serverURLKey = "offlineMap.serverURL"
    private static let apiTokenKey = "offlineMap.apiToken"
    private static let centerLatitudeKey = "offlineMap.centerLatitude"
    private static let centerLongitudeKey = "offlineMap.centerLongitude"
    private static let sideLengthKey = "offlineMap.sideLengthKm"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURLString = defaults.string(forKey: Self.serverURLKey) ?? ""
        self.apiToken = defaults.string(forKey: Self.apiTokenKey) ?? ""
        self.centerLatitude = defaults.string(forKey: Self.centerLatitudeKey) ?? "35.16755"
        self.centerLongitude = defaults.string(forKey: Self.centerLongitudeKey) ?? "136.89451"
        self.sideLengthKm = defaults.string(forKey: Self.sideLengthKey) ?? "25"
    }

    func createCustomCutoutJob() {
        Task {
            await runBusy {
                let client = try self.makeClient()
                let request = try self.makeCustomBBoxRequest()
                self.currentJob = try await client.createJob(request)
                self.downloadURL = nil
                self.downloadedPackURL = nil
                self.transferProgress = 0
                self.statusMessage = self.currentJob?.status ?? ""
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
                let mapId = try self.readyMapId()
                let url: URL
                if let downloadURL = self.downloadURL {
                    url = downloadURL
                } else {
                    let client = try self.makeClient()
                    url = try await client.downloadURL(mapId: mapId)
                    self.downloadURL = url
                }

                let (temporaryURL, _) = try await URLSession.shared.download(from: url)
                let destination = try self.cachedPackURL(mapId: mapId)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: destination)
                self.downloadedPackURL = destination
                self.transferProgress = 0
                self.statusMessage = "pack downloaded"
            }
        }
    }

    func transferDownloadedPack(bleManager: BLEManager) {
        Task {
            await runBusy {
                let packURL: URL
                if let downloadedPackURL = self.downloadedPackURL {
                    packURL = downloadedPackURL
                } else {
                    throw OfflineMapPlatformError.missingDownloadURL
                }

                let baseURL = try await self.enableDeviceTransferMode(bleManager: bleManager)
                defer {
                    bleManager.requestMapTransferMode(enabled: false)
                }
                let archive = try await Task.detached(priority: .userInitiated) {
                    try OfflineMapPackArchive(url: packURL)
                }.value
                let sessionId = UUID().uuidString.lowercased()
                let client = MapTransferDeviceClient(baseURL: baseURL)
                self.transferProgress = 0
                self.statusMessage = "uploading to device"
                try await client.upload(archive: archive, sessionId: sessionId) { completed, total, path in
                    self.transferProgress = total == 0 ? 0 : Double(completed) / Double(total)
                    self.statusMessage = "uploaded \(completed)/\(total): \(path)"
                }
                self.statusMessage = "activating map"
                try await client.activate(sessionId: sessionId)
                self.transferProgress = 1
                self.statusMessage = "map installed"
                bleManager.requestMapTransferStatus()
            }
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

    private func makeClient() throws -> OfflineMapPlatformClient {
        guard let url = URL(string: serverURLString), url.scheme != nil else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        return OfflineMapPlatformClient(baseURL: url, apiToken: apiToken)
    }

    private func readyMapId() throws -> String {
        guard let mapId = currentJob?.mapId else {
            throw OfflineMapPlatformError.missingMapId
        }
        return mapId
    }

    private func cachedPackURL(mapId: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("OfflineMapPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(mapId).zip")
    }

    private func enableDeviceTransferMode(bleManager: BLEManager) async throws -> URL {
        guard bleManager.isNavigationReady else {
            throw OfflineMapPlatformError.missingTransferBaseURL
        }

        bleManager.requestMapTransferMode(enabled: true)
        bleManager.requestMapTransferStatus()
        for attempt in 0..<32 {
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

    private func runBusy(_ operation: @MainActor @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
