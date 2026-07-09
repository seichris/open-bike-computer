//
//  FirmwareUpdateManager.swift
//  BikeComputer
//
//  iPhone-driven firmware OTA over the shared device transfer channel.
//

import Combine
import CryptoKit
import Foundation

enum FirmwareUpdateError: LocalizedError, Equatable {
    case deviceNotReady
    case transferCommandNotSent
    case missingTransferSession
    case missingFirmwareTarget
    case invalidManifest
    case updateNotAvailable
    case unsupportedUpdaterProtocol
    case targetMismatch
    case downgradeNotAllowed
    case invalidManifestSignature
    case postRebootVerificationFailed
    case downloadSizeMismatch
    case downloadHashMismatch
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotReady:
            return "Device is not ready"
        case .transferCommandNotSent:
            return "Could not send transfer command"
        case .missingTransferSession:
            return "Device did not report a firmware transfer session"
        case .missingFirmwareTarget:
            return "Device firmware target is unknown"
        case .invalidManifest:
            return "Firmware manifest is invalid"
        case .updateNotAvailable:
            return "No newer firmware is available"
        case .unsupportedUpdaterProtocol:
            return "Firmware update requires a newer app"
        case .targetMismatch:
            return "Firmware target does not match this device"
        case .downgradeNotAllowed:
            return "Firmware downgrade is disabled"
        case .invalidManifestSignature:
            return "Firmware manifest signature is invalid"
        case .postRebootVerificationFailed:
            return "Device did not report the updated firmware after reboot"
        case .downloadSizeMismatch:
            return "Downloaded firmware size does not match the manifest"
        case .downloadHashMismatch:
            return "Downloaded firmware hash does not match the manifest"
        case .serverError(let message):
            return message
        }
    }
}

struct FirmwareReleaseManifest: Codable, Equatable {
    let schemaVersion: Int
    let target: String
    let version: String
    let build: Int
    let gitSha: String
    let size: Int
    let sha256: String
    let url: URL
    let minUpdaterProtocol: Int
    let signature: String?

    var isSupportedByApp: Bool {
        schemaVersion == 1 && minUpdaterProtocol <= 1
    }
}

struct FirmwareDeviceStatus: Decodable, Equatable {
    let status: String
    let target: String
    let runningVersion: String
    let runningBuild: Int
    let runningGitSha: String?
    let runningPartition: String
    let inactivePartition: String
    let otaState: String
    let maxImageBytes: Int
    let receivedBytes: Int
    let totalBytes: Int
    let sha256: String?
    let lastError: FirmwareStatusError?
}

struct FirmwareStatusError: Codable, Equatable {
    let code: String
    let message: String
}

struct PendingFirmwareUpdate: Codable, Equatable {
    let target: String
    let version: String
    let build: Int
    let gitSha: String
    let startedAt: Date
    var status: String
}

enum FirmwareManifestSignatureVerifier {
    static let publicKeyBase64 = "BLaIQlnOfdWu7uvpUR2V/Nhbk92m95BL+MP2ovOCAGkf4N0eDhMNH4cTiD8g6qm0IgAi2/xe0sNOMvCMGYwPlCs="

    static func verify(_ manifest: FirmwareReleaseManifest,
                       publicKeyBase64: String = publicKeyBase64) -> Bool {
        guard let signature = manifest.signature,
              let publicKeyData = Data(base64Encoded: publicKeyBase64),
              let signatureData = Data(base64Encoded: signature),
              let publicKey = try? P256.Signing.PublicKey(x963Representation: publicKeyData),
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: signatureData) else {
            return false
        }
        let payload = canonicalPayload(for: manifest)
        return publicKey.isValidSignature(signature, for: Data(payload.utf8))
    }

    static func canonicalPayload(for manifest: FirmwareReleaseManifest) -> String {
        [
            "schemaVersion=\(manifest.schemaVersion)",
            "target=\(manifest.target)",
            "version=\(manifest.version)",
            "build=\(manifest.build)",
            "gitSha=\(manifest.gitSha)",
            "size=\(manifest.size)",
            "sha256=\(manifest.sha256)",
            "url=\(manifest.url.absoluteString)",
            "minUpdaterProtocol=\(manifest.minUpdaterProtocol)"
        ].joined(separator: "\n") + "\n"
    }
}

@MainActor
final class FirmwareUpdateManager: ObservableObject {
    @Published var manifestBaseURLString: String {
        didSet { defaults.set(manifestBaseURLString, forKey: Defaults.manifestBaseURLKey) }
    }
    @Published var allowDeveloperDowngrade: Bool {
        didSet { defaults.set(allowDeveloperDowngrade, forKey: Defaults.allowDowngradeKey) }
    }
    @Published private(set) var latestManifest: FirmwareReleaseManifest?
    @Published private(set) var deviceStatus: FirmwareDeviceStatus?
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var uploadProgress: Double = 0
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastManifestURLString: String = ""
    @Published private(set) var isBusy = false

    private enum Defaults {
        static let manifestBaseURLKey = "firmware.manifestBaseURL"
        static let allowDowngradeKey = "firmware.allowDeveloperDowngrade"
        static let pendingUpdateKey = "firmware.pendingUpdate"
        static let defaultManifestBaseURL = "https://seichris.github.io/open-bike-computer/firmware"
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let deviceTransferManager = DeviceTransferManager()

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        self.manifestBaseURLString = defaults.string(forKey: Defaults.manifestBaseURLKey) ?? Defaults.defaultManifestBaseURL
        self.allowDeveloperDowngrade = defaults.bool(forKey: Defaults.allowDowngradeKey)
        if let pending = loadPendingUpdate() {
            self.statusMessage = pending.status
        }
    }

    func checkForUpdate(bleManager: BLEManager) {
        Task {
            await runBusy {
                self.statusMessage = "checking firmware manifest"
                let manifest = try await self.fetchLatestManifest(bleManager: bleManager)
                self.latestManifest = manifest
                self.statusMessage = self.availabilityMessage(for: manifest, bleManager: bleManager)
            }
        }
    }

    func installLatest(bleManager: BLEManager) {
        Task {
            await runBusy {
                let manifest: FirmwareReleaseManifest
                if let latestManifest = self.latestManifest {
                    manifest = latestManifest
                } else {
                    manifest = try await self.fetchLatestManifest(bleManager: bleManager)
                }
                try self.validateInstall(manifest, bleManager: bleManager)
                self.latestManifest = manifest
                self.statusMessage = "downloading firmware"
                self.persistPendingUpdate(manifest: manifest, status: self.statusMessage)
                self.downloadProgress = 0
                self.uploadProgress = 0
                let image = try await self.downloadFirmware(manifest: manifest)
                self.downloadProgress = 1
                try self.verify(image: image, manifest: manifest)

                var finalized = false
                let transferSession = try await self.deviceTransferManager.enterFirmwareTransfer(
                    bleManager: bleManager
                ) { message in
                    self.statusMessage = message
                }
                defer {
                    if !finalized {
                        self.deviceTransferManager.exitFirmwareTransfer(bleManager: bleManager)
                    }
                }

                let client = FirmwareUpdateDeviceClient(
                    baseURL: transferSession.baseURL,
                    sessionToken: transferSession.sessionToken ?? "",
                    session: self.session
                )
                self.statusMessage = "preparing device update"
                self.updatePendingStatus(self.statusMessage)
                self.deviceStatus = try await client.begin(manifest: manifest,
                                                           allowDowngrade: self.allowDeveloperDowngrade)
                self.statusMessage = "uploading firmware"
                self.updatePendingStatus(self.statusMessage)
                self.uploadProgress = 0
                self.deviceStatus = try await client.upload(image: image) { progress in
                    self.uploadProgress = progress
                }
                self.statusMessage = "finalizing firmware"
                self.updatePendingStatus(self.statusMessage)
                self.deviceStatus = try await client.finalize()
                finalized = true
                self.statusMessage = "device rebooting"
                self.updatePendingStatus(self.statusMessage)
                try await self.waitForPostRebootVerification(bleManager: bleManager,
                                                             manifest: manifest)
                self.statusMessage = "firmware update installed"
                self.clearPendingUpdate()
            }
        }
    }

    func refreshDeviceFirmwareStatus(bleManager: BLEManager) {
        bleManager.requestDeviceTransferStatus()
        Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.reconcilePendingUpdate(bleManager: bleManager)
        }
    }

    private func fetchLatestManifest(bleManager: BLEManager) async throws -> FirmwareReleaseManifest {
        if bleManager.firmwareTarget.isEmpty {
            bleManager.requestDeviceTransferStatus()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !bleManager.firmwareTarget.isEmpty else {
            throw FirmwareUpdateError.missingFirmwareTarget
        }
        guard let baseURL = URL(string: manifestBaseURLString) else {
            throw FirmwareUpdateError.invalidManifest
        }
        let manifestURL = baseURL
            .appendingPathComponent(bleManager.firmwareTarget)
            .appendingPathComponent("manifest.json")
        lastManifestURLString = manifestURL.absoluteString
        let (data, response) = try await session.data(from: manifestURL)
        try Self.validateHTTP(response)
        let manifest = try JSONDecoder().decode(FirmwareReleaseManifest.self, from: data)
        guard manifest.isSupportedByApp else {
            throw FirmwareUpdateError.unsupportedUpdaterProtocol
        }
        guard manifest.target == bleManager.firmwareTarget else {
            throw FirmwareUpdateError.targetMismatch
        }
        guard !manifest.version.isEmpty,
              !manifest.gitSha.isEmpty,
              manifest.size > 0,
              !manifest.sha256.isEmpty,
              manifest.signature?.isEmpty == false else {
            throw FirmwareUpdateError.invalidManifest
        }
        guard FirmwareManifestSignatureVerifier.verify(manifest) else {
            throw FirmwareUpdateError.invalidManifestSignature
        }
        return manifest
    }

    private func validateInstall(_ manifest: FirmwareReleaseManifest, bleManager: BLEManager) throws {
        guard manifest.target == bleManager.firmwareTarget else {
            throw FirmwareUpdateError.targetMismatch
        }
        if isCurrentFirmware(manifest, bleManager: bleManager) {
            throw FirmwareUpdateError.updateNotAvailable
        }
        if manifest.build <= bleManager.firmwareBuild && !allowDeveloperDowngrade {
            throw FirmwareUpdateError.updateNotAvailable
        }
    }

    func isUpdateAllowed(_ manifest: FirmwareReleaseManifest, bleManager: BLEManager) -> Bool {
        guard manifest.target == bleManager.firmwareTarget,
              !isCurrentFirmware(manifest, bleManager: bleManager) else {
            return false
        }
        return manifest.build > bleManager.firmwareBuild || allowDeveloperDowngrade
    }

    func availabilityMessage(for manifest: FirmwareReleaseManifest, bleManager: BLEManager) -> String {
        guard manifest.target == bleManager.firmwareTarget else {
            return "firmware target mismatch"
        }
        if isCurrentFirmware(manifest, bleManager: bleManager) {
            return "firmware is current"
        }
        if manifest.build > bleManager.firmwareBuild {
            return "firmware update available"
        }
        if allowDeveloperDowngrade {
            return "developer firmware install available"
        }
        return "firmware is current"
    }

    private func isCurrentFirmware(_ manifest: FirmwareReleaseManifest, bleManager: BLEManager) -> Bool {
        manifest.target == bleManager.firmwareTarget &&
        manifest.version == bleManager.firmwareVersion &&
        manifest.build == bleManager.firmwareBuild &&
        manifest.gitSha == bleManager.firmwareGitSha
    }

    private func downloadFirmware(manifest: FirmwareReleaseManifest) async throws -> Data {
        let (data, response) = try await session.data(from: manifest.url)
        try Self.validateHTTP(response)
        return data
    }

    private func verify(image: Data, manifest: FirmwareReleaseManifest) throws {
        guard image.count == manifest.size else {
            throw FirmwareUpdateError.downloadSizeMismatch
        }
        guard Self.sha256Hex(image) == manifest.sha256.lowercased() else {
            throw FirmwareUpdateError.downloadHashMismatch
        }
    }

    private func waitForPostRebootVerification(bleManager: BLEManager,
                                               manifest: FirmwareReleaseManifest) async throws {
        var sawDeviceUnavailable = !bleManager.isNavigationReady
        for attempt in 0..<90 {
            if bleManager.isNavigationReady {
                bleManager.requestDeviceTransferStatus()
                try? await Task.sleep(nanoseconds: 500_000_000)
                if sawDeviceUnavailable && isDeviceRunning(manifest, bleManager: bleManager) {
                    return
                }
            } else {
                sawDeviceUnavailable = true
                if attempt % 4 == 0 {
                    bleManager.reconnectToLastDevice()
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        updatePendingStatus("firmware update status unknown")
        throw FirmwareUpdateError.postRebootVerificationFailed
    }

    private func reconcilePendingUpdate(bleManager: BLEManager) {
        guard let pending = loadPendingUpdate() else { return }
        if bleManager.firmwareTarget == pending.target &&
            bleManager.firmwareVersion == pending.version &&
            bleManager.firmwareBuild == pending.build &&
            bleManager.firmwareGitSha == pending.gitSha {
            statusMessage = "firmware update installed"
            clearPendingUpdate()
        } else if let error = bleManager.firmwareUpdateLastError {
            statusMessage = "firmware update failed: \(error)"
            updatePendingStatus(statusMessage)
        } else {
            statusMessage = pending.status
        }
    }

    private func isDeviceRunning(_ manifest: FirmwareReleaseManifest,
                                 bleManager: BLEManager) -> Bool {
        bleManager.firmwareTarget == manifest.target &&
        bleManager.firmwareVersion == manifest.version &&
        bleManager.firmwareBuild == manifest.build &&
        bleManager.firmwareGitSha == manifest.gitSha
    }

    private func persistPendingUpdate(manifest: FirmwareReleaseManifest, status: String) {
        let pending = PendingFirmwareUpdate(target: manifest.target,
                                            version: manifest.version,
                                            build: manifest.build,
                                            gitSha: manifest.gitSha,
                                            startedAt: Date(),
                                            status: status)
        savePendingUpdate(pending)
    }

    private func updatePendingStatus(_ status: String) {
        guard var pending = loadPendingUpdate() else { return }
        pending.status = status
        savePendingUpdate(pending)
    }

    private func loadPendingUpdate() -> PendingFirmwareUpdate? {
        guard let data = defaults.data(forKey: Defaults.pendingUpdateKey) else {
            return nil
        }
        return try? JSONDecoder().decode(PendingFirmwareUpdate.self, from: data)
    }

    private func savePendingUpdate(_ pending: PendingFirmwareUpdate) {
        if let data = try? JSONEncoder().encode(pending) {
            defaults.set(data, forKey: Defaults.pendingUpdateKey)
        }
    }

    private func clearPendingUpdate() {
        defaults.removeObject(forKey: Defaults.pendingUpdateKey)
    }

    private func runBusy(_ operation: @MainActor @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        do {
            try await operation()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            statusMessage = errorMessage ?? "firmware update failed"
            updatePendingStatus(errorMessage ?? "firmware update failed")
        }
        isBusy = false
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw FirmwareUpdateError.serverError("Firmware server request failed")
        }
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct FirmwareUpdateDeviceClient {
    let baseURL: URL
    let sessionToken: String
    var session: URLSession = .shared

    func begin(manifest: FirmwareReleaseManifest,
               allowDowngrade: Bool) async throws -> FirmwareDeviceStatus {
        let body: [String: Any] = [
            "schemaVersion": manifest.schemaVersion,
            "version": manifest.version,
            "build": manifest.build,
            "target": manifest.target,
            "gitSha": manifest.gitSha,
            "size": manifest.size,
            "sha256": manifest.sha256,
            "minUpdaterProtocol": manifest.minUpdaterProtocol,
            "manifestSignature": manifest.signature ?? "",
            "releaseUrl": manifest.url.absoluteString,
            "allowDowngrade": allowDowngrade
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path: "firmware-update/begin",
                                 method: "POST",
                                 body: data,
                                 contentType: "application/json")
    }

    @MainActor
    func upload(image: Data,
                progress: @escaping @MainActor (Double) -> Void) async throws -> FirmwareDeviceStatus {
        progress(0)
        let status: FirmwareDeviceStatus = try await request(path: "firmware-update/image",
                                                             method: "PUT",
                                                             body: image,
                                                             contentType: "application/octet-stream")
        progress(1)
        return status
    }

    func finalize() async throws -> FirmwareDeviceStatus {
        try await request(path: "firmware-update/finalize",
                          method: "POST",
                          body: Data(),
                          contentType: "application/json")
    }

    private func request<T: Decodable>(path: String,
                                       method: String,
                                       body: Data?,
                                       contentType: String? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue(sessionToken, forHTTPHeaderField: "X-BikeComputer-Transfer-Token")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.upload(for: request, from: body ?? Data())
        guard let http = response as? HTTPURLResponse else {
            throw FirmwareUpdateError.serverError("Device did not return HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let message = Self.errorMessage(from: data) {
                throw FirmwareUpdateError.serverError(message)
            }
            throw FirmwareUpdateError.serverError("Device firmware request failed")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return nil
        }
        let code = error["code"] as? String ?? "error"
        let message = error["message"] as? String ?? ""
        return message.isEmpty ? code : "\(code): \(message)"
    }
}
