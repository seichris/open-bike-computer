//
//  OfflineMapManager.swift
//  BikeComputer
//
//  Coordinates offline map platform requests from the settings UI.
//

import CoreLocation
import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import Security
#endif

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
    nonisolated static let lastTransferProtocolKey = "offlineMap.lastTransfer.protocol"
    nonisolated static let lastTransferStreamFormatKey = "offlineMap.lastTransfer.streamFormat"
    nonisolated static let lastTransferArtifactFilenameKey = "offlineMap.lastTransfer.artifactFilename"
    nonisolated static let lastTransferBackgroundTaskIDKey = "offlineMap.lastTransfer.backgroundTaskID"
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
            previousSessionId != sessionId) {
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
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet,
            NSURLErrorInternationalRoamingOff,
            NSURLErrorCallIsActive,
            NSURLErrorDataNotAllowed,
        ].contains(nsError.code)
    }
}

nonisolated enum MapArchiveUploadFallback {
    static func shouldUseForeground(
        for error: Error,
        allowLocalStorageFailure: Bool = false
    ) -> Bool {
        if let platformError = error as? OfflineMapPlatformError,
           case .serverStatus(let status, _) = platformError,
           status == 400 || status == 413 {
            // Older firmware rejects pack.zip as an unknown path (400).
            // Current firmware caps a single archive at 512 MiB (413), while
            // its per-file protocol can still accept the same valid map.
            return true
        }
        return allowLocalStorageFailure && isLocalStorageFailure(error)
    }

    private static func isLocalStorageFailure(
        _ error: Error,
        depth: Int = 0
    ) -> Bool {
        guard depth < 4 else { return false }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain &&
            nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        if nsError.domain == NSURLErrorDomain && [
            URLError.Code.fileDoesNotExist.rawValue,
            URLError.Code.noPermissionsToReadFile.rawValue,
            URLError.Code.cannotOpenFile.rawValue,
            URLError.Code.cannotCreateFile.rawValue,
            URLError.Code.dataLengthExceedsMaximum.rawValue,
        ].contains(nsError.code) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 28 {
            return true
        }
        guard let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error else {
            return false
        }
        return isLocalStorageFailure(underlying, depth: depth + 1)
    }
}

nonisolated enum MapArchiveUploadStrategy {
    static func requiresCompatibilityArchive(for archive: OfflineMapPackArchive) -> Bool {
        archive.entries.contains { $0.path == "preview.png" }
    }
}

@MainActor
final class OfflineMapPreviewLoadRegistry {
    private var tokens: [String: UUID] = [:]

    func begin(for key: String) -> UUID {
        let token = UUID()
        tokens[key] = token
        return token
    }

    func finishIfCurrent(_ token: UUID, for key: String) -> Bool {
        guard tokens[key] == token else { return false }
        tokens.removeValue(forKey: key)
        return true
    }

    func invalidate(_ key: String) {
        tokens.removeValue(forKey: key)
    }

    func removeAll() {
        tokens.removeAll()
    }
}

private enum PreparedMapTransfer {
    case stream(VerifiedBikeMapArtifact, SavedMapArtifactMetadata)
    case archive(OfflineMapPackArchive, mapID: String, sessionID: String)

    var mapID: String {
        switch self {
        case .stream(let artifact, _): artifact.mapID
        case .archive(_, let mapID, _): mapID
        }
    }

    var sessionID: String {
        switch self {
        case .stream(let artifact, _): artifact.signedManifestReceipt
        case .archive(_, _, let sessionID): sessionID
        }
    }
}

private enum MapTransferControl: Error {
    case legacyArtifactRequired(SavedMapArtifactMetadata)
}

nonisolated enum MapTransferOutcomePolicy {
    static func outcome(after error: Error, activationMayBeInFlight: Bool) -> String {
        if activationMayBeInFlight,
           let platformError = error as? OfflineMapPlatformError,
           case .serverStatus(let status, _) = platformError,
           status == 408 {
            return "unconfirmed"
        }
        if activationMayBeInFlight,
           error is CancellationError || MapActivationTransport.isAmbiguousResponseError(error) {
            return "unconfirmed"
        }
        return "failed"
    }
}

nonisolated enum MapActivationConfirmationResult: Equatable {
    case installed
    case continuesOnDevice(lastState: String)
}

nonisolated enum CachedPackRecoveryDecision: Equatable {
    case installed
    case pending
    case absent

    static func evaluate(
        expectedSessionId: String,
        activeSessionId: String,
        activationStatus: String,
        activationSessionId: String
    ) -> CachedPackRecoveryDecision {
        if activeSessionId == expectedSessionId {
            return .installed
        }
        if activationSessionId == expectedSessionId,
           ["receiving", "paused", "finalizing", "ready", "activating", "installed"]
            .contains(activationStatus) {
            return .pending
        }
        return .absent
    }
}

nonisolated enum ExistingMapStreamAttemptDisposition: Equatable {
    case upload
    case awaitDevice
    case installed

    static func evaluate(
        expectedSessionID: String,
        activeSessionID: String?,
        activationStatus: String?,
        activationSessionID: String?
    ) -> Self {
        if activeSessionID == expectedSessionID {
            return .installed
        }
        guard activationSessionID == expectedSessionID else { return .upload }
        switch activationStatus {
        case "installed":
            return .installed
        case "receiving", "finalizing", "ready", "activating":
            return .awaitDevice
        default:
            // Paused and failed streams need a matching retry from byte zero.
            return .upload
        }
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

nonisolated enum OfflineMapInstallationCredentialStoreError: LocalizedError {
    case persistenceFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .persistenceFailure(let status):
            "Could not securely save the map service installation credential (\(status))."
        }
    }
}

nonisolated struct OfflineMapInstallationCredentialStore {
    private static let service = "org.openbikecomputer.map-platform-installation-v1"
    private static let fallbackKeyPrefix = "offlineMap.installationCredential."
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load(serverURLString: String) -> OfflineMapInstallationCredential? {
        let account = OfflineMapServerIdentity.normalized(serverURLString)
#if os(iOS)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
#else
        guard let data = defaults.data(forKey: Self.fallbackKeyPrefix + account) else {
            return nil
        }
#endif
        return try? JSONDecoder().decode(OfflineMapInstallationCredential.self, from: data)
    }

    func save(
        _ credential: OfflineMapInstallationCredential,
        serverURLString: String
    ) throws {
        let account = OfflineMapServerIdentity.normalized(serverURLString)
        let data = try JSONEncoder().encode(credential)
#if os(iOS)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = identity
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw OfflineMapInstallationCredentialStoreError.persistenceFailure(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw OfflineMapInstallationCredentialStoreError.persistenceFailure(updateStatus)
        }
#else
        defaults.set(data, forKey: Self.fallbackKeyPrefix + account)
#endif
    }
}

nonisolated struct SavedMapArtifactMetadata: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let mapID: String
    var displayName: String?
    let localArtifactFilename: String
    let streamFormatVersion: Int?
    let jobID: String?
    let serverURLString: String?
    let clientInstallationID: String?
    let primaryArtifact: OfflineMapArtifact?
    let legacyArtifact: OfflineMapArtifact?
    var lastTransferProtocol: Int?
    var lastTransferStreamFormat: Int?
    var lastTransferSessionID: String?
    var lastBackgroundTaskID: Int?
    var lastDeviceSequence: UInt32?
    var lastDeviceState: String?
    var lastDeviceStep: Int?
    var lastDeviceStepCount: Int?
    var lastDeviceProgress: Int?
    var expectedActiveMapID: String?
    var expectedActiveSessionID: String?
    var lastTransferOutcome: String?
    var userDefinedDisplayName: Bool? = nil
    var downloadReceiptID: String? = nil
}

nonisolated enum SavedMapArtifactMetadataStore {
    static func metadataURL(for artifactURL: URL) -> URL {
        artifactURL.appendingPathExtension("map.json")
    }

    static func load(for artifactURL: URL) -> SavedMapArtifactMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(for: artifactURL)),
              let metadata = try? JSONDecoder().decode(SavedMapArtifactMetadata.self, from: data),
              metadata.schemaVersion == SavedMapArtifactMetadata.currentSchemaVersion,
              metadata.localArtifactFilename == artifactURL.lastPathComponent else {
            return nil
        }
        return metadata
    }

    static func save(_ metadata: SavedMapArtifactMetadata, for artifactURL: URL) throws {
        guard metadata.schemaVersion == SavedMapArtifactMetadata.currentSchemaVersion,
              metadata.localArtifactFilename == artifactURL.lastPathComponent else {
            throw OfflineMapPlatformError.invalidPack("saved map metadata does not match its artifact")
        }
        let data = try JSONEncoder.offlineMap.encode(metadata)
        try data.write(to: metadataURL(for: artifactURL), options: .atomic)
    }

    static func delete(for artifactURL: URL) throws {
        let url = metadataURL(for: artifactURL)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

nonisolated enum SavedMapStreamMigrationFallback {
    static func shouldUseLegacyArtifact(
        for metadata: SavedMapArtifactMetadata
    ) -> Bool {
        guard let primary = metadata.primaryArtifact,
              primary.isBikeMapStream,
              primary.signatureKeySha256 == nil,
              primary.producerBuildSha256 == nil,
              metadata.legacyArtifact?.isStoredZip == true else {
            return false
        }
        return true
    }
}

nonisolated enum OfflineMapArtifactDownloadChoice: Equatable {
    case bikeMapStream(OfflineMapArtifact, legacy: OfflineMapArtifact?)
    case legacyZip(OfflineMapArtifact?)
}

nonisolated enum OfflineMapArtifactSelector {
    static func select(
        artifacts: [OfflineMapArtifact],
        trustStore: BikeMapStreamTrustStore,
        canDownloadStreamArtifact: Bool = true
    ) throws -> OfflineMapArtifactDownloadChoice {
        let streams = artifacts.filter(\.isBikeMapStream)
        let legacyArtifacts = artifacts.filter(\.isStoredZip)
        guard streams.count <= 1, legacyArtifacts.count <= 1 else {
            throw OfflineMapPlatformError.invalidResponse
        }
        let legacy = legacyArtifacts.first
        // Jobs owned by the pre-registration installation UUID cannot use the
        // new installation-token-protected immutable artifact endpoint. Keep
        // their durable ZIP path recoverable throughout the migration window.
        guard canDownloadStreamArtifact else { return .legacyZip(legacy) }
        let trustedStreams = streams.filter { artifact in
            artifact.signatureKeyId.map(trustStore.contains(keyID:)) == true
        }
        if let stream = trustedStreams.first {
            return .bikeMapStream(stream, legacy: legacy)
        }
        if !streams.isEmpty, !trustStore.isEmpty {
            throw BikeMapStreamFormatError.unknownKeyID(
                streams.compactMap(\.signatureKeyId).first ?? "missing"
            )
        }
        return .legacyZip(legacy)
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

nonisolated struct OfflineMapActivityCounter {
    private(set) var count = 0

    var isBusy: Bool { count > 0 }

    mutating func begin() {
        count += 1
    }

    mutating func end() {
        precondition(count > 0, "offline map activity counter is unbalanced")
        count -= 1
    }
}

@MainActor
final class OfflineMapManager: ObservableObject {
    typealias PackDownloadOperation = (
        URL,
        OfflineMapDownloadConstraints,
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
    @Published private(set) var hasActiveBackgroundUpload = false
    @Published private(set) var isServerRecoveryCheckPending = false
    @Published private(set) var isMapAreaSelectionActive = false
    @Published private(set) var selectedMapBounds: OfflineMapBounds?
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var activationProgress: MapActivationProgressPresentation?
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

    var hasPendingDeviceActivation: Bool {
        lastTransferOutcome == "unconfirmed"
    }

    var hasPausedMapUpload: Bool {
        guard let packURL = try? cachedPackURL(mapId: lastTransferMapId) else {
            return false
        }
        return isPausedMapUpload(packURL)
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
    private let installationCredentialStore: OfflineMapInstallationCredentialStore
    private let mapStreamTrustStore: BikeMapStreamTrustStore
    private let legacyClientInstallationId: String
    private(set) var clientInstallationId: String
    private(set) var clientInstallationToken: String?
    private let deviceTransferManager = DeviceTransferManager()
    @Published private var packDisplayNames: [String: String]
    private var mapJobTask: Task<Void, Never>?
    private var mapJobTaskID: UUID?
    private var inventorySyncTask: Task<Void, Never>?
    private var activationReconciliationTask: Task<Void, Never>?
    private var backgroundUploadObserver: AnyCancellable?
    private var activityCounter = OfflineMapActivityCounter()
#if canImport(UIKit)
    @Published private var packPreviewImages: [String: UIImage] = [:]
    private var unavailablePackPreviews: Set<String> = []
    private var previewLoadTasks: [String: Task<Void, Never>] = [:]
    private let previewLoadRegistry = OfflineMapPreviewLoadRegistry()
#endif

    init(
        defaults: UserDefaults = .standard,
        mapPlatformSession: URLSession = .shared,
        cacheDirectory: URL? = nil,
        mapStreamTrustStore: BikeMapStreamTrustStore = .production,
        packDownload: @escaping PackDownloadOperation = { url, constraints, onProgress, onByteProgress in
            try await OfflineMapPackDownloader.download(
                from: url,
                constraints: constraints,
                onProgress: onProgress,
                onByteProgress: onByteProgress
            )
        }
    ) {
        OfflineMapPackCompatibilityArchive.removeOrphans()
        self.defaults = defaults
        self.mapPlatformSession = mapPlatformSession
        self.packDownload = packDownload
        self.cacheDirectoryOverride = cacheDirectory
        self.installationCredentialStore = OfflineMapInstallationCredentialStore(defaults: defaults)
        self.mapStreamTrustStore = mapStreamTrustStore
        let resolvedServerURL = Self.resolvedServerURL(defaults: defaults)
        let installationCredential = installationCredentialStore.load(
            serverURLString: resolvedServerURL
        )
        let legacyInstallationID = OfflineMapInstallationIdentity.resolve(defaults: defaults)
        self.legacyClientInstallationId = legacyInstallationID
        self.clientInstallationId = installationCredential?.clientInstallationId ??
            legacyInstallationID
        self.clientInstallationToken = installationCredential?.clientInstallationToken
        self.packDisplayNames = defaults.dictionary(forKey: OfflineMapDefaults.packDisplayNamesKey) as? [String: String] ?? [:]
        self.serverURLString = resolvedServerURL
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
        restoreLastTransferPresentation()
#if os(iOS)
        backgroundUploadObserver = NotificationCenter.default.publisher(
            for: BackgroundMapUploadStateStore.didChangeNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.restoreLastTransferPresentation()
                self?.refreshBackgroundUploadActivity()
            }
        }
        BackgroundMapUploadCoordinator.shared.restorePersistedTasks()
        refreshBackgroundUploadActivity()
#endif
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
            var client = try manager.makeClient()
            if try await manager.recoverOwnedServerJobIfAvailable(
                client: client,
                bleManager: bleManager
            ) {
                return
            }
            client = try await manager.ensureRegisteredInstallation(client: client)
            let request = OfflineMapJobRequest
                .customBBox(OfflineMapBounds(
                    center: location.coordinate,
                    sideLengthKm: Double(manager.sideLengthKm) ?? 25
                ))
                .identified(
                    clientInstallationId: client.clientInstallationId,
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
        syncDownloadedMapInventoryIfNeeded()
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
                    serverURLString: recoveryServerURL,
                    clientInstallationId: client.clientInstallationId
                ) {
                    manager.isServerRecoveryCheckPending = false
                    manager.statusMessage = ""
                    return
                }
                guard let recovered = manager.selectOwnedRecoverableJob(
                    from: jobs,
                    clientInstallationId: client.clientInstallationId
                ) else {
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
        startCachedPackTransfer(
            at: packURL,
            bleManager: bleManager,
            resumePausedUpload: isPausedMapUpload(packURL)
        )
    }

    func resumePausedMapUpload(bleManager: BLEManager) {
        guard let packURL = try? cachedPackURL(mapId: lastTransferMapId),
              isPausedMapUpload(packURL) else {
            return
        }
        startCachedPackTransfer(
            at: packURL,
            bleManager: bleManager,
            resumePausedUpload: true
        )
    }

    func isPausedMapUpload(_ packURL: URL) -> Bool {
        let metadata = SavedMapArtifactMetadataStore.load(for: packURL)
        return PausedMapUploadResumePolicy.isAvailable(
            lastTransferOutcome: lastTransferOutcome,
            lastTransferMapID: lastTransferMapId,
            candidateMapID: savedMapID(for: packURL),
            lastDeviceState: metadata?.lastDeviceState,
            statusMessage: statusMessage
        )
    }

    private func startCachedPackTransfer(
        at packURL: URL,
        bleManager: BLEManager,
        resumePausedUpload: Bool
    ) {
        Task {
            await runBusy {
                try await self.transferPack(
                    at: packURL,
                    bleManager: bleManager,
                    resumePausedUpload: resumePausedUpload
                )
            }
        }
    }

    func deleteCachedPack(at packURL: URL) {
        do {
            let mapID = savedMapID(for: packURL)
            if FileManager.default.fileExists(atPath: packURL.path) {
                try FileManager.default.removeItem(at: packURL)
            }
            invalidateCachedPreview(for: packURL)
            try SavedMapArtifactMetadataStore.delete(for: packURL)
            try deleteCompatibilityArtifacts(mapID: mapID)
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
        if let displayName = SavedMapArtifactMetadataStore.load(for: packURL)?.displayName,
           !displayName.isEmpty {
            return displayName
        }
        if currentJob?.mapId == packURL.deletingPathExtension().lastPathComponent,
           let displayName = displayNameForCurrentJob() {
            return displayName
        }
        return packURL.deletingPathExtension().lastPathComponent
    }

#if canImport(UIKit)
    func previewImage(forCachedPack packURL: URL) -> UIImage? {
        packPreviewImages[previewCacheKey(for: packURL)]
    }

    func loadPreviewIfNeeded(forCachedPack packURL: URL) {
        let key = previewCacheKey(for: packURL)
        guard packPreviewImages[key] == nil,
              !unavailablePackPreviews.contains(key),
              previewLoadTasks[key] == nil else {
            return
        }
        let token = previewLoadRegistry.begin(for: key)
        previewLoadTasks[key] = Task { [weak self] in
            let data = await Task.detached(priority: .utility) {
                OfflineMapPackPreviewReader.imageData(for: packURL)
            }.value
            guard let self else { return }
            guard self.previewLoadRegistry.finishIfCurrent(
                token,
                for: key
            ) else { return }
            self.previewLoadTasks.removeValue(forKey: key)
            guard !Task.isCancelled,
                  self.cachedPackURLs.contains(where: {
                      self.previewCacheKey(for: $0) == key
                  }) else {
                return
            }
            guard let data,
                  let image = UIImage(data: data),
                  image.size.width > 0,
                  image.size.height > 0,
                  image.size.width <= 512,
                  image.size.height <= 512 else {
                self.unavailablePackPreviews.insert(key)
                return
            }
            self.packPreviewImages[key] = image
        }
    }
#endif

    @discardableResult
    func renameCachedPack(at packURL: URL, to proposedName: String) -> String {
        let displayName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            return self.displayName(forCachedPack: packURL)
        }
        packDisplayNames[packURL.lastPathComponent] = displayName
        if var metadata = SavedMapArtifactMetadataStore.load(for: packURL) {
            metadata.displayName = displayName
            metadata.userDefinedDisplayName = true
            try? SavedMapArtifactMetadataStore.save(metadata, for: packURL)
        }
        persistPackDisplayNames()
        syncSavedMapInventory(packURL)
        return displayName
    }

    func isCachedPackInstalled(_ packURL: URL,
                               activeMapId: String,
                               activeSessionId: String) -> Bool {
        guard !activeMapId.isEmpty,
              activeMapId == savedMapID(for: packURL) else {
            return false
        }
        // A stable map ID identifies an area, not a particular generated pack.
        // Older firmware does not expose the content-derived session, so it
        // cannot prove that a regenerated same-area pack is already installed.
        guard !activeSessionId.isEmpty else { return false }
        if let metadata = SavedMapArtifactMetadataStore.load(for: packURL),
           metadata.primaryArtifact?.isBikeMapStream == true,
           let signedReceipt = metadata.primaryArtifact?.signedManifestReceipt,
           !signedReceipt.isEmpty {
            let acceptedSessions = [
                signedReceipt,
                metadata.expectedActiveSessionID,
                metadata.lastTransferSessionID,
            ].compactMap { value in
                value?.isEmpty == false ? value : nil
            }
            return acceptedSessions.contains(activeSessionId)
        }
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
        for filename in ["\(mapId).bmap", "\(mapId).zip"] {
            if let displayName = packDisplayNames[filename], !displayName.isEmpty {
                return displayName
            }
            if let directory = try? cachedPackDirectory(),
               let displayName = SavedMapArtifactMetadataStore.load(
                   for: directory.appendingPathComponent(filename)
               )?.displayName,
               !displayName.isEmpty {
                return displayName
            }
        }
        return mapId
    }

    func reconcileLastTransfer(bleManager: BLEManager) {
        updateActivationProgress(
            status: bleManager.mapTransferActivationStatus,
            step: bleManager.mapTransferActivationStep,
            stepCount: bleManager.mapTransferActivationStepCount,
            percentage: bleManager.mapTransferActivationProgress
        )
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
        updateSavedMapDeviceState(
            mapID: lastTransferMapId,
            sequence: bleManager.mapTransferActivationSequence,
            state: bleManager.mapTransferActivationStatus,
            step: bleManager.mapTransferActivationStep,
            stepCount: bleManager.mapTransferActivationStepCount,
            progress: bleManager.mapTransferActivationProgress
        )
        switch evaluation.decision {
        case .installed:
            updateLastTransferOutcome("installed")
            statusMessage = "map installed: \(displayName(forMapId: lastTransferMapId))"
            errorMessage = nil
        case .failed(let message):
            updateLastTransferOutcome("failed")
            statusMessage = ""
            errorMessage = OfflineMapPlatformError
                .mapActivationFailed(message)
                .localizedDescription
        case .pending:
            let deviceIsIdleOnAnotherMap =
                bleManager.mapTransferActivationStatus == "idle" &&
                bleManager.mapTransferActiveSessionId != sessionId
            switch bleManager.mapTransferActivationStatus {
            case "receiving":
                statusMessage = "Map upload continues on device"
            case "paused":
                statusMessage = "Map upload paused. Tap Upload to resume."
            case "finalizing", "ready", "activating":
                statusMessage = "Activation continues on device"
            default:
                statusMessage = deviceIsIdleOnAnotherMap
                    ? "Activation paused. Tap Upload to resume."
                    : "Waiting for device map status"
            }
            errorMessage = nil
            startActivationReconciliationMonitor(bleManager: bleManager)
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
            var client = try manager.makeClient()
            if try await manager.recoverOwnedServerJobIfAvailable(
                client: client,
                bleManager: nil
            ) {
                return
            }
            client = try await manager.ensureRegisteredInstallation(client: client)
            manager.currentJob = nil
            manager.downloadURL = nil
            manager.downloadedPackURL = nil
            manager.downloadProgress = 0
            manager.downloadByteProgress = nil
            manager.transferProgress = 0
            manager.statusMessage = "creating map job"

            let identifiedRequest = request.identified(
                clientInstallationId: client.clientInstallationId,
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

    private func selectOwnedRecoverableJob(
        from jobs: [OfflineMapJob],
        clientInstallationId: String
    ) -> OfflineMapJob? {
        OfflineMapJobRecoverySelector.select(
            jobs: jobs,
            clientInstallationId: clientInstallationId,
            excludedJobIds: OfflineMapRecoveryHistory.handledJobIds(defaults: defaults)
        )
    }

    private func consumeForgottenDiscovery(
        jobs: [OfflineMapJob],
        serverURLString: String,
        clientInstallationId: String
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
            serverURLString: client.baseURL.absoluteString,
            clientInstallationId: client.clientInstallationId
        ) {
            return false
        }
        guard let recovered = selectOwnedRecoverableJob(
            from: jobs,
            clientInstallationId: client.clientInstallationId
        ) else { return false }
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

    private func syncDownloadedMapInventoryIfNeeded() {
        guard inventorySyncTask == nil else { return }
        let packURLs = cachedPackURLs
        inventorySyncTask = Task { [weak self] in
            guard let self else { return }
            defer { self.inventorySyncTask = nil }
            do {
                let client = try self.makeClient()
                guard client.clientInstallationToken?.isEmpty == false else { return }
                let jobs = try await client.jobs()
                for packURL in packURLs {
                    await self.syncSavedMapInventory(
                        packURL,
                        client: client,
                        jobs: jobs
                    )
                }
            } catch {
                // Inventory sync is best-effort. A later app activation retries
                // the stable receipt and any explicit user label.
            }
        }
    }

    private func syncSavedMapInventory(_ packURL: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let client = try self.makeClient()
                guard client.clientInstallationToken?.isEmpty == false else { return }
                let jobs = try await client.jobs()
                await self.syncSavedMapInventory(
                    packURL,
                    client: client,
                    jobs: jobs
                )
            } catch {
                // The app remains the local source of truth until the next
                // idempotent background sync succeeds.
            }
        }
    }

    private func syncSavedMapInventory(
        _ packURL: URL,
        client: OfflineMapPlatformClient,
        jobs: [OfflineMapJob]
    ) async {
        guard var metadata = SavedMapArtifactMetadataStore.load(for: packURL),
              let jobID = metadata.jobID,
              let savedServerURL = metadata.serverURLString,
              let savedInstallationID = metadata.clientInstallationID,
              savedInstallationID == client.clientInstallationId,
              OfflineMapServerIdentity.normalized(savedServerURL) ==
                OfflineMapServerIdentity.normalized(client.baseURL.absoluteString),
              let job = jobs.first(where: { $0.jobId == jobID }) else {
            return
        }

        if metadata.downloadReceiptID == nil {
            metadata.downloadReceiptID = UUID().uuidString.lowercased()
        }
        if metadata.userDefinedDisplayName == nil {
            let localName = metadata.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sourceName = job.sourceRegion?.name
                .trimmingCharacters(in: .whitespacesAndNewlines)
            metadata.userDefinedDisplayName = {
                guard let localName, !localName.isEmpty,
                      let sourceName, !sourceName.isEmpty else {
                    return false
                }
                return Self.cleanDisplayName(localName).localizedCaseInsensitiveCompare(
                    Self.cleanDisplayName(sourceName)
                ) != .orderedSame
            }()
        }
        try? SavedMapArtifactMetadataStore.save(metadata, for: packURL)

        let artifact = metadata.primaryArtifact ?? job.artifacts?.first(where: { value in
            if packURL.pathExtension.lowercased() == "bmap" {
                return value.isBikeMapStream
            }
            return value.isStoredZip
        })
        let fileBytes = (try? packURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init)
        guard let receiptID = metadata.downloadReceiptID,
              let byteCount = artifact?.bytes ?? fileBytes,
              byteCount > 0 else {
            return
        }
        let receipt = OfflineMapDownloadReceiptRequest(
            receiptId: receiptID,
            artifactFormat: artifact?.format ?? OfflineMapArtifact.storedZipFormat,
            sha256: artifact?.sha256,
            bytes: byteCount
        )
        do {
            try await client.recordDownload(jobId: jobID, receipt: receipt)
            if metadata.userDefinedDisplayName == true,
               let displayName = metadata.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !displayName.isEmpty {
                try await client.updateDisplayName(
                    jobId: jobID,
                    displayName: displayName
                )
            }
        } catch {
            // Preserve the stable local receipt for a later retry.
        }
    }

    private func makeClient(
        serverURLString: String? = nil,
        apiTokenString: String? = nil
    ) throws -> OfflineMapPlatformClient {
        let value = serverURLString ?? self.serverURLString
        guard let url = URL(string: value), url.scheme != nil else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        let credential = installationCredentialStore.load(serverURLString: value)
        let installationID = credential?.clientInstallationId ?? legacyClientInstallationId
        let resolvedAPIToken: String?
        if let apiTokenString {
            resolvedAPIToken = apiTokenString
        } else if OfflineMapServerIdentity.isManaged(value) {
            let bundled = OfflineMapServiceConfig.apiToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedAPIToken = bundled.isEmpty ? apiToken : bundled
        } else if OfflineMapServerIdentity.normalized(value) ==
            OfflineMapServerIdentity.normalized(self.serverURLString) {
            resolvedAPIToken = apiToken
        } else {
            resolvedAPIToken = nil
        }
        return OfflineMapPlatformClient(
            baseURL: url,
            apiToken: resolvedAPIToken,
            clientInstallationId: installationID,
            clientInstallationToken: credential?.clientInstallationToken,
            session: mapPlatformSession
        )
    }

    private func ensureRegisteredInstallation(
        client: OfflineMapPlatformClient
    ) async throws -> OfflineMapPlatformClient {
        if client.clientInstallationToken?.isEmpty == false {
            return client
        }
        do {
            let credential = try await client.registerInstallation()
            try installationCredentialStore.save(
                credential,
                serverURLString: client.baseURL.absoluteString
            )
            if OfflineMapServerIdentity.normalized(client.baseURL.absoluteString) ==
                OfflineMapServerIdentity.normalized(serverURLString) {
                clientInstallationId = credential.clientInstallationId
                clientInstallationToken = credential.clientInstallationToken
            }
            return OfflineMapPlatformClient(
                baseURL: client.baseURL,
                apiToken: client.apiToken,
                clientInstallationId: credential.clientInstallationId,
                clientInstallationToken: credential.clientInstallationToken,
                session: mapPlatformSession
            )
        } catch let error as OfflineMapPlatformError {
            if case .serverStatus(let status, _) = error, status == 404 || status == 405 {
                return client
            }
            throw error
        }
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
        guard let job = currentJob else {
            throw OfflineMapPlatformError.invalidResponse
        }
        let choice = try OfflineMapArtifactSelector.select(
            artifacts: job.artifacts ?? [],
            trustStore: mapStreamTrustStore,
            canDownloadStreamArtifact: client.clientInstallationToken?.isEmpty == false
        )
        let url: URL
        let fileExtension: String
        let primaryArtifact: OfflineMapArtifact?
        let legacyArtifact: OfflineMapArtifact?
        switch choice {
        case .bikeMapStream(let artifact, let legacy):
            url = try await client.artifactDownloadURL(
                mapId: mapId,
                jobId: job.jobId,
                artifact: artifact
            )
            fileExtension = "bmap"
            primaryArtifact = artifact
            legacyArtifact = legacy
        case .legacyZip(let artifact):
            url = try await client.downloadURL(mapId: mapId, jobId: job.jobId)
            fileExtension = "zip"
            primaryArtifact = artifact
            legacyArtifact = nil
        }
        downloadURL = url

        statusMessage = "downloading map"
        downloadProgress = 0
        downloadByteProgress = nil
        var temporaryURL: URL?
        var verifiedStream: VerifiedBikeMapArtifact?
        let trustStore = mapStreamTrustStore
        do {
            let constraints = try OfflineMapDownloadConstraints.mapArtifact(primaryArtifact)
            let downloadedURL = try await packDownload(url, constraints, { [weak self] progress in
                self?.downloadProgress = progress
            }, { [weak self] byteProgress in
                self?.downloadByteProgress = byteProgress
            })
            temporaryURL = downloadedURL
            let validationTask = Task.detached(priority: .userInitiated) {
                () throws -> VerifiedBikeMapArtifact? in
                switch choice {
                case .bikeMapStream(let artifact, _):
                    return try BikeMapStreamArtifactValidator.validate(
                        url: downloadedURL,
                        artifact: artifact,
                        expectedMapID: mapId,
                        trustStore: trustStore
                    )
                case .legacyZip(let artifact):
                    if let artifact {
                        try OfflineMapArtifactFileValidator.validate(
                            url: downloadedURL,
                            artifact: artifact
                        )
                    }
                    let archive = try OfflineMapPackArchive(url: downloadedURL)
                    try archive.validate(expectedMapId: mapId)
                    return nil
                }
            }
            verifiedStream = try await withTaskCancellationHandler {
                try await validationTask.value
            } onCancel: {
                validationTask.cancel()
            }
            try Task.checkCancellation()
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
        let destination = try cachedPackURL(mapId: mapId, fileExtension: fileExtension)
        let existingMetadata = ["bmap", "zip"]
            .compactMap { try? cachedPackURL(mapId: mapId, fileExtension: $0) }
            .compactMap { SavedMapArtifactMetadataStore.load(for: $0) }
            .first
        let existingDisplayName = ["\(mapId).bmap", "\(mapId).zip"]
            .compactMap { packDisplayNames[$0] }
            .first { !$0.isEmpty }
        let defaultDisplayName = verifiedStream?.displayName ?? displayNameForCurrentJob()
        let displayName = existingDisplayName ?? defaultDisplayName
        let userDefinedDisplayName = existingMetadata?.userDefinedDisplayName ?? {
            guard let existingDisplayName, let defaultDisplayName else { return false }
            return Self.cleanDisplayName(existingDisplayName).localizedCaseInsensitiveCompare(
                Self.cleanDisplayName(defaultDisplayName)
            ) != .orderedSame
        }()
        let downloadReceiptID = UUID().uuidString.lowercased()
        let metadata = SavedMapArtifactMetadata(
            schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
            mapID: mapId,
            displayName: displayName,
            localArtifactFilename: destination.lastPathComponent,
            streamFormatVersion: fileExtension == "bmap" ? 1 : nil,
            jobID: job.jobId,
            serverURLString: client.baseURL.absoluteString,
            clientInstallationID: client.clientInstallationId,
            primaryArtifact: primaryArtifact,
            legacyArtifact: legacyArtifact,
            lastTransferProtocol: nil,
            lastTransferStreamFormat: nil,
            lastTransferSessionID: nil,
            lastBackgroundTaskID: nil,
            lastDeviceSequence: nil,
            lastDeviceState: nil,
            lastDeviceStep: nil,
            lastDeviceStepCount: nil,
            lastDeviceProgress: nil,
            expectedActiveMapID: mapId,
            expectedActiveSessionID: nil,
            lastTransferOutcome: nil,
            userDefinedDisplayName: userDefinedDisplayName,
            downloadReceiptID: downloadReceiptID
        )
        let backup = destination
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).backup")
        let metadataURL = SavedMapArtifactMetadataStore.metadataURL(for: destination)
        let metadataBackup = SavedMapArtifactMetadataStore.metadataURL(for: backup)
        var backedUpArtifact = false
        var backedUpMetadata = false
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: backup)
                backedUpArtifact = true
            }
            if FileManager.default.fileExists(atPath: metadataURL.path) {
                try FileManager.default.moveItem(at: metadataURL, to: metadataBackup)
                backedUpMetadata = true
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            try SavedMapArtifactMetadataStore.save(metadata, for: destination)
            let obsoleteExtension = fileExtension == "bmap" ? "zip" : "bmap"
            let obsolete = try cachedPackURL(mapId: mapId, fileExtension: obsoleteExtension)
            if FileManager.default.fileExists(atPath: obsolete.path) {
                try? FileManager.default.removeItem(at: obsolete)
                try? SavedMapArtifactMetadataStore.delete(for: obsolete)
                packDisplayNames.removeValue(forKey: obsolete.lastPathComponent)
                invalidateCachedPreview(for: obsolete)
            }
            if backedUpArtifact { try? FileManager.default.removeItem(at: backup) }
            if backedUpMetadata { try? FileManager.default.removeItem(at: metadataBackup) }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            try? FileManager.default.removeItem(at: destination)
            try? SavedMapArtifactMetadataStore.delete(for: destination)
            if backedUpArtifact {
                try? FileManager.default.moveItem(at: backup, to: destination)
            }
            if backedUpMetadata {
                try? FileManager.default.moveItem(at: metadataBackup, to: metadataURL)
            }
            downloadURL = nil
            throw error
        }
        invalidateCachedPreview(for: destination)
        downloadedPackURL = destination
        OfflineMapJobPersistence.markPackDownloaded(
            jobId: job.jobId,
            mapId: mapId,
            defaults: defaults
        )
        if packDisplayNames[destination.lastPathComponent]?.isEmpty != false,
           let displayName {
            packDisplayNames[destination.lastPathComponent] = displayName
        }
        persistPackDisplayNames()
        let receiptBytes = primaryArtifact?.bytes ?? Int64(
            (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        if receiptBytes > 0 {
            try? await client.recordDownload(
                jobId: job.jobId,
                receipt: OfflineMapDownloadReceiptRequest(
                    receiptId: downloadReceiptID,
                    artifactFormat: primaryArtifact?.format ?? OfflineMapArtifact.storedZipFormat,
                    sha256: primaryArtifact?.sha256,
                    bytes: receiptBytes
                )
            )
        }
        if userDefinedDisplayName, let displayName, !displayName.isEmpty {
            try? await client.updateDisplayName(jobId: job.jobId, displayName: displayName)
        }
        refreshCachedPacks()
#if canImport(UIKit)
        loadPreviewIfNeeded(forCachedPack: destination)
#endif
        downloadProgress = 1
        downloadByteProgress = nil
        transferProgress = 0
        statusMessage = "map downloaded"
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
            if let downloadedPackURL {
                let deviceState = await cachedPackDeviceState(
                    downloadedPackURL,
                    bleManager: bleManager
                )
                if deviceState == .pending {
                    statusMessage = "map activation is still running on device"
                    return
                }
                if deviceState == .installed {
                    statusMessage = "map installed: \(displayName(forCachedPack: downloadedPackURL))"
                    updateLastTransferOutcome("installed")
                    clearPersistedJob(markHandled: true)
                    return
                }
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
            if let downloadedPackURL {
                let deviceState = await cachedPackDeviceState(
                    downloadedPackURL,
                    bleManager: bleManager
                )
                if deviceState == .pending {
                    statusMessage = "map activation is still running on device"
                    return
                }
                if deviceState == .installed {
                    statusMessage = "map installed: \(displayName(forCachedPack: downloadedPackURL))"
                    updateLastTransferOutcome("installed")
                    clearPersistedJob(markHandled: true)
                    return
                }
            }
            try await transferReadyPack(bleManager: bleManager)
        }
        clearPersistedJob(markHandled: true)
    }

    private func cachedPackDeviceState(
        _ packURL: URL,
        bleManager: BLEManager
    ) async -> CachedPackRecoveryDecision {
        guard let identity = try? transferIdentity(for: packURL) else {
            return .absent
        }
        let expectedSessionId = identity.sessionID
        guard bleManager.requestMapTransferStatus() else { return .absent }
        _ = await bleManager.waitForNavigationWritesToDrain(timeoutSeconds: 2)
        let initialDeadline = Date().addingTimeInterval(2)
        var activationDeadline: Date?
        var pollCount = 0
        while true {
            if Task.isCancelled { return .pending }
            let decision = CachedPackRecoveryDecision.evaluate(
                expectedSessionId: expectedSessionId,
                activeSessionId: bleManager.mapTransferActiveSessionId,
                activationStatus: bleManager.mapTransferActivationStatus,
                activationSessionId: bleManager.mapTransferActivationSessionId
            )
            switch decision {
            case .installed:
                return .installed
            case .pending:
                if activationDeadline == nil {
                    activationDeadline = Date().addingTimeInterval(
                        OfflineMapDefaults.activationConfirmationTimeout
                    )
                }
            case .absent:
                if bleManager.mapTransferActivationSessionId == expectedSessionId,
                   bleManager.mapTransferActivationStatus == "failed" {
                    return .absent
                }
                break
            }
            let now = Date()
            if let activationDeadline {
                if now >= activationDeadline { return .pending }
            } else if now >= initialDeadline {
                return .absent
            }
            pollCount += 1
            if pollCount % 10 == 0 {
                bleManager.requestMapTransferStatus()
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
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

    private func transferPack(
        at packURL: URL,
        bleManager: BLEManager,
        resumePausedUpload: Bool = false
    ) async throws {
        var resumeProgressFloor: Int
        if resumePausedUpload {
            let lastVisibleProgress = max(
                activationProgress?.percentage ?? 0,
                SavedMapArtifactMetadataStore.load(for: packURL)?.lastDeviceProgress ?? 0
            )
            resumeProgressFloor = min(max(lastVisibleProgress, 0), 100)
        } else {
            resumeProgressFloor = 0
        }
        statusMessage = "preparing transfer"
        transferProgress = 0
        activationProgress = resumeProgressFloor > 0
            ? MapActivationProgressPresentation(
                step: 1,
                stepCount: 3,
                percentage: resumeProgressFloor
            )
            : nil
        if packURL.pathExtension.lowercased() == "bmap",
           let metadata = SavedMapArtifactMetadataStore.load(for: packURL),
           SavedMapStreamMigrationFallback.shouldUseLegacyArtifact(for: metadata) {
            let legacyURL = try await materializeLegacyFallback(for: metadata)
            try await transferPack(at: legacyURL, bleManager: bleManager)
            return
        }
        let trustStore = mapStreamTrustStore
        let validationTask = Task.detached(priority: .userInitiated) {
            if packURL.pathExtension.lowercased() == "bmap" {
                guard let metadata = SavedMapArtifactMetadataStore.load(for: packURL),
                      metadata.mapID == packURL.deletingPathExtension().lastPathComponent,
                      let artifact = metadata.primaryArtifact,
                      artifact.isBikeMapStream else {
                    throw OfflineMapPlatformError.invalidPack(
                        "signed map metadata is missing or does not match"
                    )
                }
                let verified = try BikeMapStreamArtifactValidator.validate(
                    url: packURL,
                    artifact: artifact,
                    expectedMapID: metadata.mapID,
                    trustStore: trustStore
                )
                return PreparedMapTransfer.stream(verified, metadata)
            }
            if let artifact = SavedMapArtifactMetadataStore.load(for: packURL)?.primaryArtifact {
                try OfflineMapArtifactFileValidator.validate(url: packURL, artifact: artifact)
            }
            let archive = try OfflineMapPackArchive(url: packURL)
            guard let mapId = try archive.manifest().mapId, !mapId.isEmpty,
                  let manifestEntry = archive.manifestEntry else {
                throw OfflineMapPlatformError.invalidPack("manifest.json has no mapId")
            }
            try archive.validate(expectedMapId: mapId)
            let sessionID = MapTransferSessionIdentity.make(
                mapId: mapId,
                manifestData: try archive.data(for: manifestEntry)
            )
            return PreparedMapTransfer.archive(
                archive,
                mapID: mapId,
                sessionID: sessionID
            )
        }
        let prepared = try await withTaskCancellationHandler {
            try await validationTask.value
        } onCancel: {
            validationTask.cancel()
        }
        try Task.checkCancellation()
        let expectedMapId = prepared.mapID
        let sessionId = prepared.sessionID
        var activationMayBeInFlight = false

#if os(iOS)
        let activeUploadActivity = await BackgroundMapUploadCoordinator.shared
            .activeUploadActivity()
        switch BackgroundMapUploadArbitration.evaluate(
            active: activeUploadActivity.descriptors,
            hasUnidentifiedActiveUpload: activeUploadActivity.hasUnidentifiedTask,
            mapID: expectedMapId,
            sessionID: sessionId,
            resumeRequested: resumePausedUpload
        ) {
        case .retainExisting:
            if case .stream = prepared {
                retainExistingStreamAttempt(
                    mapID: expectedMapId,
                    sessionID: sessionId,
                    artifactURL: packURL,
                    activeMapID: bleManager.mapTransferActiveMapId,
                    activeSessionID: bleManager.mapTransferActiveSessionId,
                    activationStatus: "receiving",
                    activationSequence: bleManager.mapTransferActivationSequence,
                    activationSessionID: sessionId,
                    activationStep: 1,
                    activationStepCount: 3,
                    activationProgress: BackgroundMapUploadStateStore.latest(
                        mapID: expectedMapId,
                        sessionID: sessionId,
                        defaults: defaults
                    )?.percentage,
                    bleManager: bleManager
                )
            } else {
                statusMessage = "Map upload continues on device"
                if let upload = BackgroundMapUploadStateStore.latest(
                    mapID: expectedMapId,
                    sessionID: sessionId,
                    defaults: defaults
                ), let percentage = upload.percentage {
                    transferProgress = Double(percentage) / 100
                }
            }
            return
        case .retireExisting:
            break
        case .blockForOther:
            throw OfflineMapPlatformError.backgroundMapUploadInProgress
        case .begin:
            break
        }
        if resumePausedUpload {
            guard await BackgroundMapUploadCoordinator.shared.retireActiveUpload(
                mapID: expectedMapId,
                sessionID: sessionId
            ) else {
                throw OfflineMapPlatformError.backgroundMapUploadInProgress
            }
            let remainingActivity = await BackgroundMapUploadCoordinator.shared
                .activeUploadActivity()
            hasActiveBackgroundUpload = remainingActivity.hasActiveTask
            guard BackgroundMapUploadArbitration.evaluate(
                active: remainingActivity.descriptors,
                hasUnidentifiedActiveUpload: remainingActivity.hasUnidentifiedTask,
                mapID: expectedMapId,
                sessionID: sessionId
            ) == .begin else {
                throw OfflineMapPlatformError.backgroundMapUploadInProgress
            }
        }
#endif

        if case .stream = prepared {
            let disposition = ExistingMapStreamAttemptDisposition.evaluate(
                expectedSessionID: sessionId,
                activeSessionID: bleManager.mapTransferActiveSessionId,
                activationStatus: bleManager.mapTransferActivationStatus,
                activationSessionID: bleManager.mapTransferActivationSessionId
            )
            if disposition != .upload {
                retainExistingStreamAttempt(
                    mapID: expectedMapId,
                    sessionID: sessionId,
                    artifactURL: packURL,
                    activeMapID: bleManager.mapTransferActiveMapId,
                    activeSessionID: bleManager.mapTransferActiveSessionId,
                    activationStatus: bleManager.mapTransferActivationStatus,
                    activationSequence: bleManager.mapTransferActivationSequence,
                    activationSessionID: bleManager.mapTransferActivationSessionId,
                    activationStep: bleManager.mapTransferActivationStep,
                    activationStepCount: bleManager.mapTransferActivationStepCount,
                    activationProgress: bleManager.mapTransferActivationProgress,
                    bleManager: bleManager
                )
                return
            }
        }

        do {
            if resumePausedUpload {
                statusMessage = "restarting device transfer mode"
                await deviceTransferManager.exitMapTransfer(bleManager: bleManager)
            }
            let transferSession = try await deviceTransferManager.enterMapTransfer(
                bleManager: bleManager
            ) { message in
                self.statusMessage = message
            }
            try await withBackgroundTransferLifecycle(bleManager: bleManager) {
                let client = MapTransferDeviceClient(
                    baseURL: transferSession.baseURL,
                    sessionToken: transferSession.sessionToken
                )
                let initialDeviceStatus = try await client.status()
                if case .stream = prepared,
                   let activation = initialDeviceStatus.activation,
                   activation.sessionId == sessionId,
                   activation.step == 1,
                   let deviceProgress = activation.progress {
                    resumeProgressFloor = MapUploadProgressReconciler.percentage(
                        retryTransportPercentage: resumeProgressFloor,
                        durableDevicePercentage: deviceProgress
                    ) ?? 0
                    updateSavedMapDeviceState(
                        mapID: expectedMapId,
                        sequence: activation.sequence,
                        state: activation.status ?? "paused",
                        step: activation.step,
                        stepCount: activation.steps,
                        progress: deviceProgress
                    )
                }
                if case .stream(let artifact, let metadata) = prepared,
                   MapInstallProtocolSelector.select(
                       isBikeMapStream: true,
                       signatureTrustCapability:
                           "\(artifact.signatureKeyID)=\(artifact.signatureKeySHA256)",
                       requiredIosBuild: artifact.requiredIosBuild,
                       requiredIosGitSha: artifact.requiredIosGitSHA,
                       requiredIosBuildSha256: artifact.requiredIosBuildSHA256,
                       currentIosBuild: MapStreamAppBuildIdentity.current?.build,
                       currentIosGitSha: MapStreamAppBuildIdentity.current?.gitSha,
                       currentIosBuildSha256:
                           MapStreamAppBuildIdentity.current?.componentSha256,
                       compatibleArtifactAppIdentities:
                           MapStreamAppArtifactCompatibilityPolicy
                               .resumablePredecessorIdentities,
                       requiredFirmwareVersion: artifact.requiredFirmwareVersion,
                       requiredFirmwareBuild: artifact.requiredFirmwareBuild,
                       requiredFirmwareGitSha: artifact.requiredFirmwareGitSHA,
                       deviceStatus: initialDeviceStatus
                   ) == .legacyArtifactRequired {
                    throw MapTransferControl.legacyArtifactRequired(metadata)
                }
                if case .stream = prepared {
                    let disposition = ExistingMapStreamAttemptDisposition.evaluate(
                        expectedSessionID: sessionId,
                        activeSessionID: initialDeviceStatus.activeSessionId,
                        activationStatus: initialDeviceStatus.activation?.status,
                        activationSessionID: initialDeviceStatus.activation?.sessionId
                    )
                    if disposition != .upload {
                        retainExistingStreamAttempt(
                            mapID: expectedMapId,
                            sessionID: sessionId,
                            artifactURL: packURL,
                            activeMapID: initialDeviceStatus.activeMapId,
                            activeSessionID: initialDeviceStatus.activeSessionId,
                            activationStatus: initialDeviceStatus.activation?.status,
                            activationSequence: initialDeviceStatus.activation?.sequence,
                            activationSessionID: initialDeviceStatus.activation?.sessionId,
                            activationStep: initialDeviceStatus.activation?.step,
                            activationStepCount: initialDeviceStatus.activation?.steps,
                            activationProgress: initialDeviceStatus.activation?.progress,
                            bleManager: bleManager
                        )
                        return
                    }
                }
                transferProgress = 0
                statusMessage = "uploading \(displayName(forMapId: expectedMapId)) to device"
                let protocolVersion: Int
                let streamFormatVersion: Int?
                switch prepared {
                case .stream:
                    protocolVersion = 2
                    streamFormatVersion = 1
                case .archive:
                    protocolVersion = 1
                    streamFormatVersion = nil
                }
                recordTransfer(
                    mapId: expectedMapId,
                    sessionId: sessionId,
                    previousMapId: initialDeviceStatus.activeMapId ??
                        bleManager.mapTransferActiveMapId,
                    previousSessionId: initialDeviceStatus.activeSessionId ??
                        bleManager.mapTransferActiveSessionId,
                    previousSequence: initialDeviceStatus.activation?.sequence ??
                        bleManager.mapTransferActivationSequence,
                    outcome: "uploading",
                    protocolVersion: protocolVersion,
                    streamFormatVersion: streamFormatVersion,
                    artifactURL: packURL
                )

                switch prepared {
                case .archive(let archive, _, _):
                    var compatibilityArchiveURL: URL?
                    var useForegroundTransfer = false
                    if MapArchiveUploadStrategy.requiresCompatibilityArchive(
                        for: archive
                    ) {
                        statusMessage = "preparing compatible map transfer"
                        let sourceURL = packURL
                        let preparation = Task.detached(priority: .utility) {
                            try Task.checkCancellation()
                            let sourceArchive = try OfflineMapPackArchive(url: sourceURL)
                            return try OfflineMapPackCompatibilityArchive.make(
                                from: sourceArchive
                            )
                        }
                        do {
                            compatibilityArchiveURL = try await withTaskCancellationHandler {
                                try await preparation.value
                            } onCancel: {
                                preparation.cancel()
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            useForegroundTransfer = true
                        }
                    }
                    defer {
                        if let compatibilityArchiveURL {
                            OfflineMapPackCompatibilityArchive.remove(
                                compatibilityArchiveURL
                            )
                        }
                    }
                    try Task.checkCancellation()

                    if !useForegroundTransfer {
                        do {
                            try await client.uploadArchiveInBackground(
                                archiveURL: compatibilityArchiveURL ?? packURL,
                                sessionId: sessionId,
                                descriptor: BackgroundMapUploadDescriptor(
                                    mapID: expectedMapId,
                                    sessionID: sessionId,
                                    protocolVersion: 1,
                                    streamFormatVersion: nil,
                                    artifactFilename: packURL.lastPathComponent,
                                    accessPointSSID: transferSession.accessPointSSID
                                ),
                                onTaskStarted: { taskID in
                                    self.recordBackgroundUploadTask(
                                        taskID,
                                        mapID: expectedMapId
                                    )
                                    if let compatibilityArchiveURL {
                                        OfflineMapPackCompatibilityArchive.remove(
                                            compatibilityArchiveURL
                                        )
                                    }
                                }
                            ) { completedBytes, totalBytes in
                                self.transferProgress = totalBytes == 0 ? 0 :
                                    Double(completedBytes) / Double(totalBytes)
                                let percent = Int((self.transferProgress * 100).rounded())
                                self.statusMessage = "uploading \(self.displayName(forMapId: expectedMapId)): \(percent)%"
                            }
                        } catch {
                            guard MapArchiveUploadFallback.shouldUseForeground(
                                for: error,
                                allowLocalStorageFailure:
                                    compatibilityArchiveURL != nil
                            ) else {
                                throw error
                            }
                            useForegroundTransfer = true
                        }
                    }
                    if useForegroundTransfer {
                        statusMessage = "device uses foreground map transfer"
                        try await client.upload(
                            archive: archive,
                            sessionId: sessionId
                        ) { completed, total, path, didUpload in
                            self.transferProgress = total == 0 ? 0 :
                                Double(completed) / Double(total)
                            let prefix = didUpload ? "uploaded" : "already on device"
                            self.statusMessage = "\(prefix) \(completed)/\(total): \(path)"
                        }
                    }
                    transferProgress = 1
                    try await beginLegacyActivationAndConfirm(
                        expectedMapID: expectedMapId,
                        sessionID: sessionId,
                        initialDeviceStatus: initialDeviceStatus,
                        client: client,
                        bleManager: bleManager,
                        artifactURL: packURL,
                        activationMayBeInFlight: &activationMayBeInFlight
                    )
                case .stream(let artifact, _):
                    activationMayBeInFlight = true
                    let retryProgressFloor = resumeProgressFloor
                    try await client.uploadStreamInBackground(
                        artifact: artifact,
                        sessionId: sessionId,
                        descriptor: BackgroundMapUploadDescriptor(
                            mapID: expectedMapId,
                            sessionID: sessionId,
                            protocolVersion: 2,
                            streamFormatVersion: 1,
                            artifactFilename: packURL.lastPathComponent,
                            accessPointSSID: transferSession.accessPointSSID
                        ),
                        onTaskStarted: { taskID in
                            self.recordBackgroundUploadTask(
                                taskID,
                                mapID: expectedMapId
                            )
                        }
                    ) { completedBytes, totalBytes in
                        self.transferProgress = totalBytes == 0 ? 0 :
                            Double(completedBytes) / Double(totalBytes)
                        let percent = MapUploadProgressReconciler.percentage(
                            retryTransportPercentage:
                                Int((self.transferProgress * 100).rounded()),
                            durableDevicePercentage: retryProgressFloor
                        ) ?? 0
                        self.activationProgress = MapActivationProgressPresentation(
                            step: 1,
                            stepCount: 3,
                            percentage: percent
                        )
                    }
                    transferProgress = 1
                    try await confirmStreamActivation(
                        expectedMapID: expectedMapId,
                        sessionID: sessionId,
                        initialDeviceStatus: initialDeviceStatus,
                        client: client,
                        bleManager: bleManager,
                        artifactURL: packURL
                    )
                }
                bleManager.requestMapTransferStatus()
            }
        } catch MapTransferControl.legacyArtifactRequired(let metadata) {
            let legacyURL = try await materializeLegacyFallback(for: metadata)
            try await transferPack(at: legacyURL, bleManager: bleManager)
        } catch {
            let outcome = MapTransferOutcomePolicy.outcome(
                after: error,
                activationMayBeInFlight: activationMayBeInFlight
            )
            updateLastTransferOutcome(outcome)
            if outcome == "unconfirmed" {
                statusMessage = "Map upload paused. Tap Upload to resume."
                errorMessage = nil
                startActivationReconciliationMonitor(bleManager: bleManager)
                return
            }
            throw error
        }
    }

    private func materializeLegacyFallback(
        for metadata: SavedMapArtifactMetadata
    ) async throws -> URL {
        guard let artifact = metadata.legacyArtifact,
              artifact.isStoredZip,
              let jobID = metadata.jobID,
              let serverURLString = metadata.serverURLString,
              let ownerInstallationID = metadata.clientInstallationID else {
            throw OfflineMapPlatformError.firmwareMapStreamUnsupported
        }
        let client = try makeClient(serverURLString: serverURLString)
        guard client.clientInstallationId == ownerInstallationID,
              client.clientInstallationToken?.isEmpty == false else {
            throw OfflineMapPlatformError.firmwareMapStreamUnsupported
        }
        let directory = try cachedPackDirectory()
            .appendingPathComponent("Compatibility", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            "\(metadata.mapID)-\(artifact.sha256.prefix(12)).zip"
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            do {
                try await validateLegacyArtifact(
                    at: destination,
                    artifact: artifact,
                    expectedMapID: metadata.mapID
                )
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination)
                try? SavedMapArtifactMetadataStore.delete(for: destination)
            }
        }

        statusMessage = "downloading compatible map for this device"
        let url = try await client.artifactDownloadURL(
            mapId: metadata.mapID,
            jobId: jobID,
            artifact: artifact
        )
        var temporaryURL: URL?
        do {
            let constraints = try OfflineMapDownloadConstraints.mapArtifact(artifact)
            let downloaded = try await packDownload(url, constraints, { [weak self] progress in
                self?.downloadProgress = progress
            }, { [weak self] byteProgress in
                self?.downloadByteProgress = byteProgress
            })
            temporaryURL = downloaded
            try await validateLegacyArtifact(
                at: downloaded,
                artifact: artifact,
                expectedMapID: metadata.mapID
            )
            try FileManager.default.moveItem(at: downloaded, to: destination)
            let fallbackMetadata = SavedMapArtifactMetadata(
                schemaVersion: SavedMapArtifactMetadata.currentSchemaVersion,
                mapID: metadata.mapID,
                displayName: metadata.displayName,
                localArtifactFilename: destination.lastPathComponent,
                streamFormatVersion: nil,
                jobID: jobID,
                serverURLString: serverURLString,
                clientInstallationID: ownerInstallationID,
                primaryArtifact: artifact,
                legacyArtifact: nil,
                lastTransferProtocol: 1,
                lastTransferStreamFormat: nil,
                lastTransferSessionID: nil,
                lastBackgroundTaskID: nil,
                lastDeviceSequence: nil,
                lastDeviceState: nil,
                lastDeviceStep: nil,
                lastDeviceStepCount: nil,
                lastDeviceProgress: nil,
                expectedActiveMapID: metadata.mapID,
                expectedActiveSessionID: nil,
                lastTransferOutcome: nil
            )
            try SavedMapArtifactMetadataStore.save(fallbackMetadata, for: destination)
            downloadProgress = 1
            downloadByteProgress = nil
            return destination
        } catch {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
            throw error
        }
    }

    private func retainExistingStreamAttempt(
        mapID: String,
        sessionID: String,
        artifactURL: URL,
        activeMapID: String?,
        activeSessionID: String?,
        activationStatus: String?,
        activationSequence: UInt32?,
        activationSessionID: String?,
        activationStep: Int?,
        activationStepCount: Int?,
        activationProgress: Int?,
        bleManager: BLEManager
    ) {
        let disposition = ExistingMapStreamAttemptDisposition.evaluate(
            expectedSessionID: sessionID,
            activeSessionID: activeSessionID,
            activationStatus: activationStatus,
            activationSessionID: activationSessionID
        )
        recordTransfer(
            mapId: mapID,
            sessionId: sessionID,
            previousMapId: activeMapID,
            previousSessionId: activeSessionID,
            previousSequence: activationSequence,
            outcome: disposition == .installed ? "installed" : "unconfirmed",
            protocolVersion: 2,
            streamFormatVersion: 1,
            artifactURL: artifactURL
        )
        updateSavedMapDeviceState(
            mapID: mapID,
            sequence: activationSequence,
            state: activationStatus ?? "receiving",
            step: activationStep,
            stepCount: activationStepCount,
            progress: activationProgress
        )
        updateActivationProgress(
            status: activationStatus ?? "receiving",
            step: activationStep,
            stepCount: activationStepCount,
            percentage: activationProgress
        )
        if let activationSequence {
            defaults.set(
                Int(activationSequence),
                forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey
            )
        }
        switch disposition {
        case .installed:
            transferProgress = 1
            statusMessage = "map installed: \(displayName(forMapId: mapID))"
        case .awaitDevice:
            statusMessage = activationStatus == "receiving"
                ? "Map upload continues on device"
                : "Activation continues on device"
            startActivationReconciliationMonitor(bleManager: bleManager)
        case .upload:
            break
        }
    }

    private func validateLegacyArtifact(
        at url: URL,
        artifact: OfflineMapArtifact,
        expectedMapID: String
    ) async throws {
        let task = Task.detached(priority: .userInitiated) {
            try OfflineMapArtifactFileValidator.validate(url: url, artifact: artifact)
            let archive = try OfflineMapPackArchive(url: url)
            try archive.validate(expectedMapId: expectedMapID)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func beginLegacyActivationAndConfirm(
        expectedMapID: String,
        sessionID: String,
        initialDeviceStatus: MapTransferDeviceStatus,
        client: MapTransferDeviceClient,
        bleManager: BLEManager,
        artifactURL: URL,
        activationMayBeInFlight: inout Bool
    ) async throws {
        let statusBeforeActivation = try? await client.status()
        let activationAlreadyStarted = statusBeforeActivation?.activation?.sessionId == sessionID
        let previousMapID = statusBeforeActivation?.activeMapId ??
            initialDeviceStatus.activeMapId ?? bleManager.mapTransferActiveMapId
        let previousSessionID = statusBeforeActivation?.activeSessionId ??
            initialDeviceStatus.activeSessionId ?? bleManager.mapTransferActiveSessionId
        let previousSequence = activationAlreadyStarted
            ? bleManager.mapTransferActivationSequence
            : statusBeforeActivation?.activation?.sequence ??
                initialDeviceStatus.activation?.sequence ??
                bleManager.mapTransferActivationSequence
        recordTransfer(
            mapId: expectedMapID,
            sessionId: sessionID,
            previousMapId: previousMapID,
            previousSessionId: previousSessionID,
            previousSequence: previousSequence,
            outcome: "activating",
            protocolVersion: 1,
            artifactURL: artifactURL
        )
        statusMessage = "activating \(displayName(forMapId: expectedMapID))"
        activationProgress = nil
        bleManager.resetMapTransferActivationObservation()
        var acceptedSequence = activationAlreadyStarted
            ? statusBeforeActivation?.activation?.sequence
            : nil
        activationMayBeInFlight = true
        do {
            if let sequence = try await client.activate(sessionId: sessionID) {
                acceptedSequence = sequence
            }
            if let acceptedSequence {
                defaults.set(
                    Int(acceptedSequence),
                    forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey
                )
            }
        } catch {
            guard MapActivationTransport.isAmbiguousResponseError(error) else { throw error }
        }
        try await finishActivationConfirmation(
            expectedMapID: expectedMapID,
            sessionID: sessionID,
            previousMapID: previousMapID,
            previousSessionID: previousSessionID,
            previousSequence: previousSequence,
            acceptedSequence: acceptedSequence,
            client: client,
            bleManager: bleManager
        )
    }

    private func confirmStreamActivation(
        expectedMapID: String,
        sessionID: String,
        initialDeviceStatus: MapTransferDeviceStatus,
        client: MapTransferDeviceClient,
        bleManager: BLEManager,
        artifactURL: URL
    ) async throws {
        let statusAfterUpload = try? await client.status()
        let previousMapID = initialDeviceStatus.activeMapId ?? bleManager.mapTransferActiveMapId
        let previousSessionID = initialDeviceStatus.activeSessionId ??
            bleManager.mapTransferActiveSessionId
        let previousSequence = initialDeviceStatus.activation?.sequence ??
            bleManager.mapTransferActivationSequence
        let acceptedSequence = statusAfterUpload?.activation?.sessionId == sessionID
            ? statusAfterUpload?.activation?.sequence
            : nil
        recordTransfer(
            mapId: expectedMapID,
            sessionId: sessionID,
            previousMapId: previousMapID,
            previousSessionId: previousSessionID,
            previousSequence: previousSequence,
            outcome: "activating",
            protocolVersion: 2,
            streamFormatVersion: 1,
            artifactURL: artifactURL
        )
        if let acceptedSequence {
            defaults.set(
                Int(acceptedSequence),
                forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey
            )
        }
        bleManager.resetMapTransferActivationObservation()
        try await finishActivationConfirmation(
            expectedMapID: expectedMapID,
            sessionID: sessionID,
            previousMapID: previousMapID,
            previousSessionID: previousSessionID,
            previousSequence: previousSequence,
            acceptedSequence: acceptedSequence,
            client: client,
            bleManager: bleManager
        )
    }

    private func finishActivationConfirmation(
        expectedMapID: String,
        sessionID: String,
        previousMapID: String?,
        previousSessionID: String?,
        previousSequence: UInt32?,
        acceptedSequence: UInt32?,
        client: MapTransferDeviceClient,
        bleManager: BLEManager
    ) async throws {
        let confirmation = try await confirmActivatedMap(
            expectedMapId: expectedMapID,
            sessionId: sessionID,
            previousMapId: previousMapID,
            previousSessionId: previousSessionID,
            previousSequence: previousSequence,
            acceptedSequence: acceptedSequence,
            client: client,
            bleManager: bleManager
        )
        transferProgress = 1
        switch confirmation {
        case .installed:
            statusMessage = "map installed: \(displayName(forMapId: expectedMapID))"
            updateLastTransferOutcome("installed")
        case .continuesOnDevice:
            statusMessage = "Activation continues on device"
            updateLastTransferOutcome("unconfirmed")
            startActivationReconciliationMonitor(bleManager: bleManager)
        }
    }

    private func withBackgroundTransferLifecycle<T>(
        bleManager: BLEManager,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            let value = try await operation()
            await deviceTransferManager.exitMapTransfer(bleManager: bleManager)
            return value
        } catch {
            await deviceTransferManager.exitMapTransfer(bleManager: bleManager)
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
                             pollIntervalNanoseconds: UInt64 = OfflineMapDefaults.activationPollIntervalNanoseconds) async throws -> MapActivationConfirmationResult {
        let startedAt = Date()
        var deadline = startedAt.addingTimeInterval(timeout)
        var lastObservedState = "activation request accepted"
        var observedCurrentAttempt = false
        var lastProgress: MapActivationProgressPresentation?

        while Date() < deadline {
            var receivedHTTPStatus = false
            do {
                let status = try await client.status()
                receivedHTTPStatus = true
                let activation = status.activation
                updateActivationProgress(
                    status: activation?.status,
                    step: activation?.step,
                    stepCount: activation?.steps,
                    percentage: activation?.progress
                )
                updateSavedMapDeviceState(
                    mapID: expectedMapId,
                    sequence: activation?.sequence,
                    state: activation?.status ?? "idle",
                    step: activation?.step,
                    stepCount: activation?.steps,
                    progress: activation?.progress
                )
                if let activationProgress,
                   activationProgress != lastProgress {
                    lastProgress = activationProgress
                    deadline = Date().addingTimeInterval(timeout)
                }
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
                    return .installed
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
                updateActivationProgress(
                    status: bleManager.mapTransferActivationStatus,
                    step: bleManager.mapTransferActivationStep,
                    stepCount: bleManager.mapTransferActivationStepCount,
                    percentage: bleManager.mapTransferActivationProgress
                )
                updateSavedMapDeviceState(
                    mapID: expectedMapId,
                    sequence: bleManager.mapTransferActivationSequence,
                    state: bleManager.mapTransferActivationStatus,
                    step: bleManager.mapTransferActivationStep,
                    stepCount: bleManager.mapTransferActivationStepCount,
                    progress: bleManager.mapTransferActivationProgress
                )
                if let activationProgress,
                   activationProgress != lastProgress {
                    lastProgress = activationProgress
                    deadline = Date().addingTimeInterval(timeout)
                }
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
                    return .installed
                case .failed(let message):
                    throw OfflineMapPlatformError.mapActivationFailed(message)
                case .pending(let state):
                    lastObservedState = state
                }
            }

            statusMessage = activationProgress?.label ??
                "activating \(displayName(forMapId: expectedMapId))"
            try await Task.sleep(
                nanoseconds: pollIntervalNanoseconds
            )
        }

        return .continuesOnDevice(
            lastState: lastObservedState
        )
    }

    private func updateActivationProgress(
        status: String?,
        step: Int?,
        stepCount: Int?,
        percentage: Int?
    ) {
        activationProgress = MapActivationProgressPresentation.make(
            status: status,
            step: step,
            stepCount: stepCount,
            percentage: percentage
        )
    }

    private func restoreLastTransferPresentation() {
        guard lastTransferOutcome == "unconfirmed",
              !lastTransferMapId.isEmpty,
              let url = try? cachedPackURL(mapId: lastTransferMapId),
              let metadata = SavedMapArtifactMetadataStore.load(for: url) else {
            return
        }
        updateActivationProgress(
            status: metadata.lastDeviceState,
            step: metadata.lastDeviceStep,
            stepCount: metadata.lastDeviceStepCount,
            percentage: metadata.lastDeviceProgress
        )
        let sessionID = defaults.string(
            forKey: OfflineMapDefaults.lastTransferSessionIdKey
        ) ?? ""
        if metadata.lastDeviceStep ?? 0 <= 1,
           let upload = BackgroundMapUploadStateStore.latest(
               mapID: lastTransferMapId,
               sessionID: sessionID,
               defaults: defaults
           ),
           let percentage = MapUploadProgressReconciler.percentage(
               retryTransportPercentage: upload.percentage,
               durableDevicePercentage: metadata.lastDeviceProgress
           ) {
            activationProgress = MapActivationProgressPresentation(
                step: 1,
                stepCount: 3,
                percentage: percentage
            )
            if upload.completedAt == nil {
                statusMessage = "Map upload continues on device"
            } else if upload.succeeded == true {
                statusMessage = "Activation continues on device"
            } else {
                statusMessage = "Map upload paused. Tap Upload to resume."
            }
            return
        }
        switch metadata.lastDeviceState {
        case "receiving":
            statusMessage = "Map upload continues on device"
        case "paused":
            statusMessage = "Map upload paused. Tap Upload to resume."
        case "finalizing", "ready", "activating":
            statusMessage = "Activation continues on device"
        case "failed":
            statusMessage = "Map installation needs attention"
        default:
            statusMessage = "Checking device map transfer"
        }
    }

    private func refreshBackgroundUploadActivity() {
#if os(iOS)
        Task { @MainActor [weak self] in
            let active = await BackgroundMapUploadCoordinator.shared
                .activeUploadActivity()
            self?.hasActiveBackgroundUpload = active.hasActiveTask
        }
#endif
    }

    private func startActivationReconciliationMonitor(bleManager: BLEManager) {
        guard activationReconciliationTask == nil,
              lastTransferOutcome == "unconfirmed" else {
            return
        }
        activationReconciliationTask = Task { @MainActor [weak self, weak bleManager] in
            while !Task.isCancelled,
                  let self,
                  let bleManager,
                  self.lastTransferOutcome == "unconfirmed" {
                if bleManager.isNavigationReady {
                    bleManager.requestMapTransferStatus()
                    self.reconcileLastTransfer(bleManager: bleManager)
                }
                try? await Task.sleep(
                    nanoseconds: OfflineMapDefaults.activationPollIntervalNanoseconds
                )
            }
            self?.activationReconciliationTask = nil
        }
    }

    private func recordTransfer(mapId: String,
                                sessionId: String,
                                previousMapId: String?,
                                previousSessionId: String?,
                                previousSequence: UInt32?,
                                outcome: String,
                                protocolVersion: Int = 1,
                                streamFormatVersion: Int? = nil,
                                artifactURL: URL? = nil) {
        lastTransferMapId = mapId
        defaults.set(mapId, forKey: OfflineMapDefaults.lastTransferMapIdKey)
        defaults.set(sessionId, forKey: OfflineMapDefaults.lastTransferSessionIdKey)
        defaults.set(previousMapId ?? "", forKey: OfflineMapDefaults.lastTransferPreviousMapIdKey)
        defaults.set(previousSessionId ?? "", forKey: OfflineMapDefaults.lastTransferPreviousSessionIdKey)
        defaults.set(protocolVersion, forKey: OfflineMapDefaults.lastTransferProtocolKey)
        if let streamFormatVersion {
            defaults.set(streamFormatVersion, forKey: OfflineMapDefaults.lastTransferStreamFormatKey)
        } else {
            defaults.removeObject(forKey: OfflineMapDefaults.lastTransferStreamFormatKey)
        }
        if let artifactURL {
            defaults.set(
                artifactURL.lastPathComponent,
                forKey: OfflineMapDefaults.lastTransferArtifactFilenameKey
            )
        }
        if outcome == "uploading" {
            defaults.removeObject(
                forKey: OfflineMapDefaults.lastTransferBackgroundTaskIDKey
            )
            clearSavedMapBackgroundTask(mapID: mapId)
        }
        defaults.removeObject(forKey: OfflineMapDefaults.lastTransferAcceptedSequenceKey)
        if let previousSequence {
            defaults.set(Int(previousSequence), forKey: OfflineMapDefaults.lastTransferPreviousSequenceKey)
        } else {
            defaults.removeObject(forKey: OfflineMapDefaults.lastTransferPreviousSequenceKey)
        }
        updateSavedMapTransferMetadata(
            mapID: mapId,
            protocolVersion: protocolVersion,
            streamFormatVersion: streamFormatVersion,
            sessionID: sessionId,
            outcome: outcome
        )
        updateLastTransferOutcome(outcome)
    }

    private func updateLastTransferOutcome(_ outcome: String) {
        lastTransferOutcome = outcome
        defaults.set(outcome, forKey: OfflineMapDefaults.lastTransferOutcomeKey)
        if !lastTransferMapId.isEmpty {
            let protocolVersion = defaults.object(
                forKey: OfflineMapDefaults.lastTransferProtocolKey
            ) as? NSNumber
            let streamFormatVersion = defaults.object(
                forKey: OfflineMapDefaults.lastTransferStreamFormatKey
            ) as? NSNumber
            let sessionID = defaults.string(
                forKey: OfflineMapDefaults.lastTransferSessionIdKey
            )
            updateSavedMapTransferMetadata(
                mapID: lastTransferMapId,
                protocolVersion: protocolVersion?.intValue,
                streamFormatVersion: streamFormatVersion?.intValue,
                sessionID: sessionID,
                outcome: outcome
            )
        }
        if outcome != "unconfirmed" {
            activationReconciliationTask?.cancel()
            activationReconciliationTask = nil
        }
    }

    private func updateSavedMapTransferMetadata(
        mapID: String,
        protocolVersion: Int?,
        streamFormatVersion: Int?,
        sessionID: String?,
        outcome: String
    ) {
        guard let directory = try? cachedPackDirectory() else { return }
        for fileExtension in ["bmap", "zip"] {
            let url = directory.appendingPathComponent("\(mapID).\(fileExtension)")
            guard var metadata = SavedMapArtifactMetadataStore.load(for: url) else { continue }
            metadata.lastTransferProtocol = protocolVersion
            metadata.lastTransferStreamFormat = streamFormatVersion
            metadata.lastTransferSessionID = sessionID
            metadata.expectedActiveMapID = mapID
            metadata.expectedActiveSessionID = sessionID
            metadata.lastTransferOutcome = outcome
            try? SavedMapArtifactMetadataStore.save(metadata, for: url)
        }
    }

    private func updateSavedMapDeviceState(
        mapID: String,
        sequence: UInt32?,
        state: String,
        step: Int?,
        stepCount: Int?,
        progress: Int?
    ) {
        guard let directory = try? cachedPackDirectory() else { return }
        for fileExtension in ["bmap", "zip"] {
            let url = directory.appendingPathComponent("\(mapID).\(fileExtension)")
            guard var metadata = SavedMapArtifactMetadataStore.load(for: url) else { continue }
            if metadata.lastDeviceSequence == sequence,
               metadata.lastDeviceState == state,
               metadata.lastDeviceStep == step,
               metadata.lastDeviceStepCount == stepCount,
               metadata.lastDeviceProgress == progress {
                continue
            }
            metadata.lastDeviceSequence = sequence
            metadata.lastDeviceState = state
            metadata.lastDeviceStep = step
            metadata.lastDeviceStepCount = stepCount
            metadata.lastDeviceProgress = progress
            try? SavedMapArtifactMetadataStore.save(metadata, for: url)
        }
    }

    private func recordBackgroundUploadTask(_ taskID: Int, mapID: String) {
        defaults.set(taskID, forKey: OfflineMapDefaults.lastTransferBackgroundTaskIDKey)
        guard let directory = try? cachedPackDirectory() else { return }
        for fileExtension in ["bmap", "zip"] {
            let url = directory.appendingPathComponent("\(mapID).\(fileExtension)")
            guard var metadata = SavedMapArtifactMetadataStore.load(for: url) else { continue }
            metadata.lastBackgroundTaskID = taskID
            try? SavedMapArtifactMetadataStore.save(metadata, for: url)
        }
    }

    private func clearSavedMapBackgroundTask(mapID: String) {
        guard let directory = try? cachedPackDirectory() else { return }
        for fileExtension in ["bmap", "zip"] {
            let url = directory.appendingPathComponent("\(mapID).\(fileExtension)")
            guard var metadata = SavedMapArtifactMetadataStore.load(for: url) else { continue }
            metadata.lastBackgroundTaskID = nil
            try? SavedMapArtifactMetadataStore.save(metadata, for: url)
        }
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
        let bmap = try cachedPackURL(mapId: mapId, fileExtension: "bmap")
        if FileManager.default.fileExists(atPath: bmap.path) {
            return bmap
        }
        return try cachedPackURL(mapId: mapId, fileExtension: "zip")
    }

    private func cachedPackURL(mapId: String, fileExtension: String) throws -> URL {
        let directory = try cachedPackDirectory()
        return directory.appendingPathComponent("\(mapId).\(fileExtension)")
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

    private func deleteCompatibilityArtifacts(mapID: String) throws {
        let directory = try cachedPackDirectory()
            .appendingPathComponent("Compatibility", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in files where url.pathExtension.lowercased() == "zip" {
            guard SavedMapArtifactMetadataStore.load(for: url)?.mapID == mapID else { continue }
            try FileManager.default.removeItem(at: url)
            try SavedMapArtifactMetadataStore.delete(for: url)
        }
    }

    private func refreshCachedPacks() {
        do {
            let directory = try cachedPackDirectory()
            let packURLs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { ["bmap", "zip"].contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
#if canImport(UIKit)
            let activePreviewKeys = Set(packURLs.map(previewCacheKey))
            for key in Array(packPreviewImages.keys) where !activePreviewKeys.contains(key) {
                packPreviewImages.removeValue(forKey: key)
            }
            for key in Array(previewLoadTasks.keys) where !activePreviewKeys.contains(key) {
                previewLoadTasks.removeValue(forKey: key)?.cancel()
                previewLoadRegistry.invalidate(key)
            }
            unavailablePackPreviews.formIntersection(activePreviewKeys)
#endif
            cacheMissingDisplayNames(for: packURLs)
            cachedPackURLs = packURLs
        } catch {
#if canImport(UIKit)
            for task in previewLoadTasks.values {
                task.cancel()
            }
            previewLoadTasks.removeAll()
            previewLoadRegistry.removeAll()
            packPreviewImages.removeAll()
            unavailablePackPreviews.removeAll()
#endif
            cachedPackURLs = []
        }
    }

#if canImport(UIKit)
    private func previewCacheKey(for packURL: URL) -> String {
        packURL.standardizedFileURL.path
    }

    private func invalidateCachedPreview(for packURL: URL) {
        let key = previewCacheKey(for: packURL)
        previewLoadRegistry.invalidate(key)
        previewLoadTasks.removeValue(forKey: key)?.cancel()
        packPreviewImages.removeValue(forKey: key)
        unavailablePackPreviews.remove(key)
    }
#else
    private func invalidateCachedPreview(for packURL: URL) {}
#endif

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
        if let displayName = SavedMapArtifactMetadataStore.load(for: packURL)?.displayName,
           !displayName.isEmpty {
            return displayName
        }
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

    private func savedMapID(for packURL: URL) -> String {
        SavedMapArtifactMetadataStore.load(for: packURL)?.mapID ??
            packURL.deletingPathExtension().lastPathComponent
    }

    private func transferIdentity(for packURL: URL) throws -> (mapID: String, sessionID: String) {
        if let metadata = SavedMapArtifactMetadataStore.load(for: packURL),
           metadata.primaryArtifact?.isBikeMapStream == true,
           let signedReceipt = metadata.primaryArtifact?.signedManifestReceipt,
           !signedReceipt.isEmpty {
            if metadata.lastTransferProtocol == 1,
               let legacySessionID = metadata.expectedActiveSessionID,
               !legacySessionID.isEmpty {
                return (metadata.mapID, legacySessionID)
            }
            return (metadata.mapID, signedReceipt)
        }
        let archive = try OfflineMapPackArchive(url: packURL)
        guard let manifestEntry = archive.manifestEntry,
              let mapID = try archive.manifest().mapId,
              !mapID.isEmpty else {
            throw OfflineMapPlatformError.invalidPack("manifest.json has no mapId")
        }
        return (
            mapID,
            MapTransferSessionIdentity.make(
                mapId: mapID,
                manifestData: try archive.data(for: manifestEntry)
            )
        )
    }

    private func runBusy(_ operation: @MainActor @escaping () async throws -> Void) async {
        activityCounter.begin()
        isBusy = activityCounter.isBusy
        errorMessage = nil
        defer {
            activityCounter.end()
            isBusy = activityCounter.isBusy
        }
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

nonisolated struct OfflineMapDownloadConstraints: Equatable {
    let exactBytes: Int64?
    let maximumBytes: Int64

    static let defaultMap = Self(
        exactBytes: nil,
        maximumBytes: BikeMapStreamFormat.maximumArtifactBytes
    )

    static func mapArtifact(_ artifact: OfflineMapArtifact?) throws -> Self {
        let exactBytes = artifact?.bytes
        if let exactBytes, exactBytes <= 0 {
            throw BikeMapStreamFormatError.invalidArtifactMetadata(
                "artifact byte count is invalid"
            )
        }
        let maximumBytes = BikeMapStreamFormat.maximumArtifactBytes
        if let exactBytes, exactBytes > maximumBytes {
            throw BikeMapStreamFormatError.invalidArtifactMetadata(
                "artifact exceeds the supported map size"
            )
        }
        return Self(exactBytes: exactBytes, maximumBytes: maximumBytes)
    }
}

final class OfflineMapPackDownloader: NSObject, URLSessionDownloadDelegate {
    private static let maximumErrorBodyBytes = 4 * 1024

    private let constraints: OfflineMapDownloadConstraints
    private let onProgress: @MainActor @Sendable (Double) -> Void
    private let onByteProgress: @MainActor @Sendable (OfflineMapByteProgress) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    private init(
        constraints: OfflineMapDownloadConstraints,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void
    ) {
        self.constraints = constraints
        self.onProgress = onProgress
        self.onByteProgress = onByteProgress
    }

    static func download(
        from url: URL,
        constraints: OfflineMapDownloadConstraints = .defaultMap,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void,
        configuration: URLSessionConfiguration = .default
    ) async throws -> URL {
        let downloader = OfflineMapPackDownloader(
            constraints: constraints,
            onProgress: onProgress,
            onByteProgress: onByteProgress
        )
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
        if let exactBytes = constraints.exactBytes,
           totalBytesExpectedToWrite > 0,
           totalBytesExpectedToWrite != exactBytes {
            failDownload(
                downloadTask,
                error: BikeMapStreamFormatError.invalidArtifactMetadata(
                    "download content length does not match"
                )
            )
            return
        }
        let permittedBytes = constraints.exactBytes ?? constraints.maximumBytes
        guard totalBytesWritten <= permittedBytes else {
            failDownload(
                downloadTask,
                error: BikeMapStreamFormatError.invalidArtifactMetadata(
                    "download exceeds the declared map size"
                )
            )
            return
        }
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
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize else {
                throw BikeMapStreamFormatError.invalidArtifactMetadata(
                    "download size is unavailable"
                )
            }
            let downloadedBytes = Int64(fileSize)
            if let exactBytes = constraints.exactBytes {
                guard downloadedBytes == exactBytes else {
                    throw BikeMapStreamFormatError.invalidArtifactMetadata(
                        "download size does not match"
                    )
                }
            } else {
                guard downloadedBytes <= constraints.maximumBytes else {
                    throw BikeMapStreamFormatError.invalidArtifactMetadata(
                        "download exceeds the supported map size"
                    )
                }
            }
            try OfflineMapDownloadResponseValidator.validate(
                response: downloadTask.response,
                errorBody: Self.boundedErrorBody(at: location)
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

    private func failDownload(_ task: URLSessionDownloadTask, error: Error) {
        guard continuation != nil else { return }
        task.cancel()
        continuation?.resume(throwing: error)
        continuation = nil
        session?.invalidateAndCancel()
    }

    private static func boundedErrorBody(at url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maximumErrorBodyBytes + 1)) ?? Data()
        let prefix = data.prefix(maximumErrorBodyBytes)
        let value = String(decoding: prefix, as: UTF8.self)
        return data.count > maximumErrorBodyBytes ? value + "\u{2026}" : value
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
