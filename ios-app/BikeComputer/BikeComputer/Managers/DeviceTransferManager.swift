//
//  DeviceTransferManager.swift
//  BikeComputer
//
//  Shared setup for BLE-controlled local Wi-Fi transfers.
//

import Foundation
import Security
#if os(iOS)
import NetworkExtension
#endif

struct DeviceTransferSession: Equatable {
    enum Mode: String, Equatable {
        case map
        case firmware
        case debug
        case diagnostics
    }

    let mode: Mode
    let baseURL: URL
    let accessPointSSID: String?
    let accessPointPassphrase: String?
    let sessionToken: String?
    let networkTransport: String?
    let networkSSID: String?
    let hotspotFallback: Bool
    let hotspotFallbackReason: String?
    let tlsCertificateSHA256: String
    let tlsIdentityVersion: UInt32
    let transferGeneration: UInt32
    let secureTransferV1: Bool
    let signedMapStreamV1: Bool
    let legacyArchivePolicy: String

    init(
        mode: Mode,
        baseURL: URL,
        accessPointSSID: String?,
        accessPointPassphrase: String? = nil,
        sessionToken: String?,
        networkTransport: String? = nil,
        networkSSID: String? = nil,
        hotspotFallback: Bool = false,
        hotspotFallbackReason: String? = nil,
        tlsCertificateSHA256: String = "",
        tlsIdentityVersion: UInt32 = 0,
        transferGeneration: UInt32 = 0,
        secureTransferV1: Bool = false,
        signedMapStreamV1: Bool = false,
        legacyArchivePolicy: String = ""
    ) {
        self.mode = mode
        self.baseURL = baseURL
        self.accessPointSSID = accessPointSSID
        self.accessPointPassphrase = accessPointPassphrase
        self.sessionToken = sessionToken
        self.networkTransport = networkTransport
        self.networkSSID = networkSSID
        self.hotspotFallback = hotspotFallback
        self.hotspotFallbackReason = hotspotFallbackReason
        self.tlsCertificateSHA256 = tlsCertificateSHA256
        self.tlsIdentityVersion = tlsIdentityVersion
        self.transferGeneration = transferGeneration
        self.secureTransferV1 = secureTransferV1
        self.signedMapStreamV1 = signedMapStreamV1
        self.legacyArchivePolicy = legacyArchivePolicy
    }
}

enum DeviceTransferSecurityError: LocalizedError, Equatable {
    case secureTransferRequired
    case signedMapStreamRequired

    var errorDescription: String? {
        switch self {
        case .secureTransferRequired:
            return "This transfer requires newer Bike Computer firmware with BLE-pinned HTTPS. Update the device firmware and try again."
        case .signedMapStreamRequired:
            return "Unsigned map archives are no longer supported. Update the device firmware and regenerate this map as a signed stream."
        }
    }
}

enum RemoteDebugHotspotFallbackReason: String {
    case endpointUnreachable = "endpoint_unreachable"

    var commandCode: String {
        switch self {
        case .endpointUnreachable: return "e"
        }
    }
}

struct RemoteDebugLANCredentials: Codable, Equatable {
    static let maximumSSIDBytes = 32
    static let minimumPasswordBytes = 8
    static let maximumPasswordBytes = 63
    static let debugCommandPrefix = "enter|debug|lan1|"
    static let diagnosticsCommandPrefix = "enter|diagnostics|lan1|"

    let ssid: String
    let password: String

    init?(ssid: String, password: String) {
        let ssidBytes = Data(ssid.utf8)
        let passwordBytes = Data(password.utf8)
        guard !ssidBytes.isEmpty,
              ssidBytes.count <= Self.maximumSSIDBytes,
              !ssid.contains("\0"),
              passwordBytes.count <= Self.maximumPasswordBytes,
              !password.contains("\0"),
              passwordBytes.isEmpty ||
                passwordBytes.count >= Self.minimumPasswordBytes else {
            return nil
        }
        self.ssid = ssid
        self.password = password
    }

    func commandPayload(for mode: DeviceTransferSession.Mode) -> Data {
        let ssidBytes = Data(ssid.utf8)
        let passwordBytes = Data(password.utf8)
        let prefix = mode == .diagnostics
            ? Self.diagnosticsCommandPrefix
            : Self.debugCommandPrefix
        var payload = Data(prefix.utf8)
        payload.append(UInt8(ssidBytes.count))
        payload.append(UInt8(passwordBytes.count))
        payload.append(ssidBytes)
        payload.append(passwordBytes)
        return payload
    }

    var commandPayload: Data { commandPayload(for: .debug) }
}

struct RemoteDebugLANCredentialStore {
    private static let service =
        "LetItRide.BikeComputer.remoteDebugLAN.v1"
    private static let account = "preferred-network"

    func load() -> RemoteDebugLANCredentials? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let decoded = try? JSONDecoder().decode(
                RemoteDebugLANCredentials.self,
                from: data
              ),
              let validated = RemoteDebugLANCredentials(
                ssid: decoded.ssid,
                password: decoded.password
              ) else { return nil }
        return validated
    }

    @discardableResult
    func save(_ credentials: RemoteDebugLANCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials) else {
            return false
        }
        let query = baseQuery()
        let update = [kSecValueData as String: data]
        let updated = SecItemUpdate(
            query as CFDictionary,
            update as CFDictionary
        )
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func remove() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}

enum DeviceDiagnosticsRejectionPolicy {
    static func message(code: String, fallback: String?) -> String {
        let explanation: String
        switch code {
        case "diagnostics_mount_failed":
            explanation = "The bike computer could not mount diagnostics storage."
        case "diagnostics_card_missing":
            explanation = "The bike computer did not detect the removable card."
        case "diagnostics_writable_probe_failed":
            explanation = "Diagnostics storage mounted, but its writable probe failed."
        case "diagnostics_flush_failed":
            explanation = "The bike computer could not flush the active diagnostics checkpoint."
        case "diagnostics_close_failed":
            explanation = "The bike computer could not close the active diagnostics checkpoint."
        case "diagnostics_seal_timeout":
            explanation = "The bike computer timed out while draining diagnostics records."
        case "diagnostics_seal_failed":
            explanation = "The bike computer could not seal a readable diagnostics checkpoint."
        case "diagnostics_index_unreadable":
            explanation = "The bike computer found a non-empty diagnostics chunk that could not be read safely."
        default:
            explanation = fallback.flatMap { $0.isEmpty ? nil : $0 } ?? code
        }
        return "\(explanation) [\(code)]"
    }
}

enum RemoteDeviceDebugError: LocalizedError, Equatable {
    case deviceNotReady
    case unsupportedFirmware
    case transferCommandNotSent
    case rejected(code: String, message: String)
    case missingSession

    var errorDescription: String? {
        switch self {
        case .deviceNotReady:
            return "The Bike Computer is not authenticated and ready."
        case .unsupportedFirmware:
            return "The connected firmware does not support remote device debugging."
        case .transferCommandNotSent:
            return "The remote-debug request could not be sent."
        case .rejected(_, let message):
            return message
        case .missingSession:
            return "The device did not return a fresh remote-debug session."
        }
    }

    var diagnosticCode: String {
        switch self {
        case .deviceNotReady: return "device_not_ready"
        case .unsupportedFirmware: return "unsupported_firmware"
        case .transferCommandNotSent: return "transfer_command_not_sent"
        case .rejected(let code, _): return code
        case .missingSession: return "missing_session"
        }
    }
}

enum RemoteDeviceDebugSessionPolicy {
    @MainActor
    static func activeSession(bleManager: BLEManager) -> DeviceTransferSession? {
        guard bleManager.deviceTransferMode == DeviceTransferSession.Mode.debug.rawValue,
              let baseURL = bleManager.deviceTransferBaseURL,
              let rawToken = bleManager.deviceTransferSessionToken,
              let token = DeviceTransferSecurityPolicy
                .normalizedTransferToken(rawToken),
              let certificateSHA256 =
                bleManager.deviceTransferTLSCertificateSHA256,
              DeviceTransferSecurityPolicy.validate(
                baseURL: baseURL,
                certificateSHA256: certificateSHA256,
                identityVersion:
                    bleManager.deviceTransferTLSIdentityVersion,
                transferGeneration: bleManager.deviceTransferGeneration,
                secureTransferV1:
                    bleManager.supportsSecureDeviceTransferV1
              ) else { return nil }
        return DeviceTransferSession(
            mode: .debug,
            baseURL: baseURL,
            accessPointSSID: bleManager.deviceTransferAccessPointSSID,
            accessPointPassphrase: bleManager.deviceTransferAccessPointPassphrase,
            sessionToken: token,
            networkTransport: bleManager.deviceTransferNetworkTransport,
            networkSSID: bleManager.deviceTransferNetworkSSID,
            hotspotFallback: bleManager.deviceTransferUsedHotspotFallback,
            hotspotFallbackReason:
                bleManager.deviceTransferHotspotFallbackReason,
            tlsCertificateSHA256: certificateSHA256,
            tlsIdentityVersion:
                bleManager.deviceTransferTLSIdentityVersion,
            transferGeneration: bleManager.deviceTransferGeneration,
            secureTransferV1: bleManager.supportsSecureDeviceTransferV1,
            signedMapStreamV1: bleManager.supportsSignedMapStreamV1,
            legacyArchivePolicy:
                bleManager.deviceTransferLegacyArchivePolicy ?? ""
        )
    }

    static func pageURL(for session: DeviceTransferSession) -> URL? {
        guard session.mode == .debug,
              session.secureTransferV1,
              DeviceTransferSecurityPolicy.validate(
                baseURL: session.baseURL,
                certificateSHA256: session.tlsCertificateSHA256,
                identityVersion: session.tlsIdentityVersion,
                transferGeneration: session.transferGeneration,
                secureTransferV1: session.secureTransferV1
              ) else { return nil }
        return session.baseURL
            .appendingPathComponent("device-debug", isDirectory: true)
    }

    static func sessionDetails(
        for session: DeviceTransferSession,
        target: String,
        deviceName: String
    ) -> String {
        [
            "Mode: \(session.mode.rawValue)",
            "Target: \(target.isEmpty ? "unknown" : target)",
            "Device: \(deviceName.isEmpty ? "unknown" : deviceName)",
            "SSID: \(session.accessPointSSID ?? "not provided")",
            "Network: \(session.networkTransport ?? "unknown")",
            "Network SSID: \(session.networkSSID ?? "not provided")",
            "Hotspot fallback: \(session.hotspotFallback ? "yes" : "no")",
            "Fallback reason: \(session.hotspotFallbackReason ?? "none")",
            "Base URL: \(session.baseURL.absoluteString)",
            "Token: present (not copied)",
        ].joined(separator: "\n")
    }
}

enum DeviceTransferHandshakePolicy {
    static let attemptCount = 32
    static let remoteDebugAttemptCount = 64
    static let retryIntervalNanoseconds: UInt64 = 250_000_000
    static let remoteDebugExitAttemptCount = 32

    static func shouldRequestStatus(attempt: Int) -> Bool {
        attempt > 0 && attempt % 4 == 0
    }

    static func diagnosticsAttemptCount(lanFirst: Bool) -> Int {
        // Diagnostics uses the same station-association worker as remote
        // debug. Give LAN-first startup enough time to reach either the LAN
        // listener or the protected-hotspot fallback.
        lanFirst ? remoteDebugAttemptCount : attemptCount
    }

}

enum DeviceTransferServerProbePolicy {
    // Firmware permits a pinned TLS handshake to occupy the single transfer
    // worker for five seconds. The client must outlive that server budget.
    static let requestTimeout: TimeInterval = 8
    static let resourceTimeout: TimeInterval = 10
    static let absoluteTimeout: TimeInterval = 20
    static let maximumAttemptCount = 3
    static let retryDelaysNanoseconds: [UInt64] = [
        0,
        750_000_000,
        2_000_000_000,
    ]

    static func makeSessionConfiguration(
        resourceTimeout: TimeInterval = resourceTimeout
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        // Keep one attempt-scoped, proxy-free session. The device closes each
        // HTTP response, but retaining the session avoids client-side route and
        // delegate churn while the accepted Wi-Fi configuration settles. The
        // exact accessory SSID is observed before this session is created, so
        // start each local request immediately. Waiting for system connectivity
        // can otherwise consume the full probe window on an accessory AP with
        // no internet path without starting a network load.
        configuration.connectionProxyDictionary = [:]
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return configuration
    }
}

enum DeviceTransferNetworkObservation: String, Equatable, Sendable {
    case target
    case other
    case unavailable

    static func classify(
        currentSSID: String?,
        expectedSSID: String
    ) -> DeviceTransferNetworkObservation {
        guard let currentSSID, !currentSSID.isEmpty else { return .unavailable }
        return currentSSID == expectedSSID ? .target : .other
    }
}

enum DeviceTransferServerProbeOutcome: Equatable, Sendable {
    case ready
    case invalidPinnedSession
    case invalidResponse
    case httpStatus(Int)
    case transportError(domain: String, code: Int)
}

struct DeviceTransferServerProbeResult: Equatable, Sendable {
    let outcome: DeviceTransferServerProbeOutcome
    let diagnostics: DeviceTransferPinnedSessionSnapshot

    var isReady: Bool {
        outcome == .ready
    }

    var shouldRetry: Bool {
        guard case .transportError = outcome else { return false }
        switch diagnostics.tlsChallengeOutcome {
        case .hostMismatch,
             .invalidExpectedFingerprint,
             .missingServerTrust,
             .certificateMismatch,
             .defaultHandling:
            return false
        case .accepted, nil:
            return true
        }
    }

    var diagnosticCode: String {
        switch outcome {
        case .ready:
            return "ready"
        case .invalidPinnedSession:
            return "invalid_pinned_session"
        case .invalidResponse:
            return "invalid_http_response"
        case .httpStatus(let status):
            return "http_\(status)"
        case .transportError:
            switch diagnostics.tlsChallengeOutcome {
            case .hostMismatch:
                return "tls_host_mismatch"
            case .invalidExpectedFingerprint:
                return "invalid_pinned_session"
            case .missingServerTrust:
                return "tls_trust_missing"
            case .certificateMismatch:
                return "tls_certificate_mismatch"
            case .defaultHandling:
                return "tls_challenge_unexpected"
            case .accepted:
                return "pinned_tls_transport_failed"
            case nil:
                if diagnostics.tlsStarted && !diagnostics.tlsCompleted {
                    return "tls_incomplete"
                }
                if diagnostics.tlsCompleted {
                    return "tls_completed_transport_failed"
                }
                if diagnostics.connectStarted &&
                    !diagnostics.connectCompleted {
                    return "connection_incomplete"
                }
                if diagnostics.connectCompleted {
                    return "tcp_connected_tls_not_started"
                }
                if diagnostics.waitedForConnectivity {
                    return "connectivity_wait_without_network_load"
                }
                return "network_not_started"
            }
        }
    }

    func diagnosticMessage(
        networkObservation: DeviceTransferNetworkObservation
    ) -> String {
        let networkPrefix: String
        switch networkObservation {
        case .target:
            networkPrefix = "accessory Wi-Fi association confirmed"
        case .other:
            return "accessory Wi-Fi association was not confirmed"
        case .unavailable:
            networkPrefix = "current Wi-Fi information was unavailable"
        }

        switch outcome {
        case .ready:
            return "device transfer server is ready"
        case .invalidPinnedSession:
            return "\(networkPrefix); the BLE-pinned HTTPS session was invalid"
        case .invalidResponse:
            return "\(networkPrefix); the pinned endpoint returned an invalid HTTP response"
        case .httpStatus(let status):
            return "\(networkPrefix); pinned HTTPS returned HTTP \(status)"
        case .transportError(let domain, let code):
            return "\(networkPrefix); no authenticated pinned HTTP 200 " +
                "(\(diagnosticCode), \(domain) \(code))"
        }
    }
}

enum DeviceNetworkJoinPolicy {
    static let applyAttemptCount = 2
    static let configurationSettleDelayNanoseconds: UInt64 = 500_000_000
    static let associationObservationTimeout: TimeInterval = 12
    static let associationObservationRetryNanoseconds: UInt64 = 250_000_000
    static let hotspotErrorDomain = "NEHotspotConfigurationErrorDomain"

    static func isAlreadyAssociated(
        domain: String,
        code: Int,
        message: String
    ) -> Bool {
        (domain == hotspotErrorDomain && code == 13) ||
            message.localizedCaseInsensitiveContains("already")
    }

    static func shouldRetry(domain: String, code: Int) -> Bool {
        guard domain == hotspotErrorDomain else { return true }
        // Internal, pending, and unknown are the only transient errors in the
        // public NEHotspotConfiguration error contract. User/policy/validation
        // failures require intervention and must not show a second join prompt.
        return code == 8 || code == 9 || code == 11
    }

    static func hasAnotherAssociationAttempt(after attempt: Int) -> Bool {
        attempt + 1 < applyAttemptCount
    }

    static func diagnosticMessage(
        domain: String,
        code: Int,
        message: String
    ) -> String {
        "\(message) [\(domain) \(code)]"
    }

    static func makeHotspotConfiguration<Configuration>(
        ssid: String,
        passphrase: String?,
        open: (String) -> Configuration,
        secured: (String, String) -> Configuration
    ) -> Configuration {
        if let passphrase, !passphrase.isEmpty {
            return secured(ssid, passphrase)
        }
        return open(ssid)
    }

#if os(iOS)
    static func hotspotConfiguration(
        ssid: String,
        passphrase: String?
    ) -> NEHotspotConfiguration {
        makeHotspotConfiguration(
            ssid: ssid,
            passphrase: passphrase,
            open: { NEHotspotConfiguration(ssid: $0) },
            secured: {
                NEHotspotConfiguration(ssid: $0, passphrase: $1, isWEP: false)
            }
        )
    }
#endif
}

struct DeviceTransferFreshFailure: Equatable {
    let code: String
    let message: String
}

enum DeviceTransferFreshFailurePolicy {
    static func failure(
        after initialSequence: UInt64?,
        currentSequence: UInt64?,
        code: String?,
        message: String?
    ) -> DeviceTransferFreshFailure? {
        guard let currentSequence,
              currentSequence != 0,
              currentSequence != initialSequence,
              let code,
              !code.isEmpty else { return nil }
        return DeviceTransferFreshFailure(
            code: code,
            message: message.flatMap { $0.isEmpty ? nil : $0 } ?? code
        )
    }
}

@MainActor
final class DeviceTransferManager {
    weak var diagnosticsRecorder: (any RideDiagnosticsEventSink)?
    private var joinedAccessPointSSID: String?

    private func record(
        mode: DeviceTransferSession.Mode,
        event: String,
        fields: [String: String] = [:]
    ) {
        var fields = fields
        fields["mode"] = mode.rawValue
        diagnosticsRecorder?.record(
            category: .transfer,
            event: event,
            fields: fields
        )
    }

    private func secureSession(
        mode: DeviceTransferSession.Mode,
        bleManager: BLEManager
    ) throws -> DeviceTransferSession? {
        guard bleManager.deviceTransferMode == mode.rawValue,
              let baseURL = bleManager.deviceTransferBaseURL,
              let rawToken = bleManager.deviceTransferSessionToken,
              let token = DeviceTransferSecurityPolicy
                .normalizedTransferToken(rawToken) else {
            return nil
        }
        guard let certificateSHA256 =
                bleManager.deviceTransferTLSCertificateSHA256,
              DeviceTransferSecurityPolicy.validate(
                baseURL: baseURL,
                certificateSHA256: certificateSHA256,
                identityVersion: bleManager.deviceTransferTLSIdentityVersion,
                transferGeneration: bleManager.deviceTransferGeneration,
                secureTransferV1: bleManager.supportsSecureDeviceTransferV1
              ) else {
            throw DeviceTransferSecurityError.secureTransferRequired
        }
        if mode == .map {
            guard bleManager.supportsSignedMapStreamV1,
                  bleManager.deviceTransferLegacyArchivePolicy == "disabled" else {
                throw DeviceTransferSecurityError.signedMapStreamRequired
            }
        }
        let transport = bleManager.deviceTransferNetworkTransport
        let accessPointSSID = bleManager.deviceTransferAccessPointSSID
        let passphrase = bleManager.deviceTransferAccessPointPassphrase
        if transport == "hotspot" {
            guard accessPointSSID?.isEmpty == false,
                  let passphrase,
                  (8...63).contains(passphrase.utf8.count) else {
                throw DeviceTransferSecurityError.secureTransferRequired
            }
        }
        return DeviceTransferSession(
            mode: mode,
            baseURL: baseURL,
            accessPointSSID: accessPointSSID,
            accessPointPassphrase: passphrase,
            sessionToken: token,
            networkTransport: transport,
            networkSSID: bleManager.deviceTransferNetworkSSID,
            hotspotFallback: bleManager.deviceTransferUsedHotspotFallback,
            hotspotFallbackReason:
                bleManager.deviceTransferHotspotFallbackReason,
            tlsCertificateSHA256: certificateSHA256,
            tlsIdentityVersion: bleManager.deviceTransferTLSIdentityVersion,
            transferGeneration: bleManager.deviceTransferGeneration,
            secureTransferV1: bleManager.supportsSecureDeviceTransferV1,
            signedMapStreamV1: bleManager.supportsSignedMapStreamV1,
            legacyArchivePolicy:
                bleManager.deviceTransferLegacyArchivePolicy ?? ""
        )
    }

    func enterMapTransfer(
        bleManager: BLEManager,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> DeviceTransferSession {
        record(mode: .map, event: "transfer_requested")
        status("requesting device transfer mode")
        guard bleManager.isNavigationReady else {
            throw OfflineMapPlatformError.missingTransferBaseURL
        }
        let initialDeviceTransferStatusRevision =
            bleManager.deviceTransferStatusRevision
        let initialDeviceTransferErrorSequence =
            bleManager.deviceTransferLastErrorSequence

        // DTRN enter is the authoritative handshake: current firmware applies
        // map mode and publishes the token-bearing DSTS response from this one
        // command. Do not wait for the shared navigation queue to become empty;
        // unrelated GPS/settings traffic may remain queued even after the
        // transfer command has been delivered.
        guard bleManager.requestDeviceTransferMode(.map) else {
            throw OfflineMapPlatformError.transferCommandNotSent
        }

        for attempt in 0..<DeviceTransferHandshakePolicy.attemptCount {
            let hasFreshDeviceStatus =
                bleManager.deviceTransferStatusRevision !=
                initialDeviceTransferStatusRevision
            if hasFreshDeviceStatus,
               let session = try secureSession(
                mode: .map,
                bleManager: bleManager
               ) {
                do {
                    try await joinDeviceNetworkIfNeeded(
                        session: session,
                        statusPath: "map-transfer/status",
                        status: status
                    )
                } catch {
                    let freshDeviceError = await freshMapTransferRejection(
                        after: initialDeviceTransferErrorSequence,
                        networkError: error,
                        bleManager: bleManager
                    )
                    await exitMapTransfer(bleManager: bleManager)
                    throw freshDeviceError ?? error
                }
                record(
                    mode: .map,
                    event: "transfer_ready",
                    fields: [
                        "networkTransport": session.networkTransport ?? "unknown",
                        "fallback": String(session.hotspotFallback),
                    ]
                )
                return session
            }
            if DeviceTransferHandshakePolicy.shouldRequestStatus(
                attempt: attempt
            ) {
                _ = bleManager.requestDeviceTransferStatus()
            }
            try await Task.sleep(
                nanoseconds:
                    DeviceTransferHandshakePolicy.retryIntervalNanoseconds
            )
        }
        // The device retains its last transfer error for diagnostics, so only
        // surface it after the full readiness window. A successful session
        // always wins over a stale error from an earlier transfer.
        if bleManager.deviceTransferStatusRevision !=
               initialDeviceTransferStatusRevision,
           let errorCode = bleManager.deviceTransferLastErrorCode,
           !errorCode.isEmpty {
            if errorCode == "sd_unavailable" {
                throw OfflineMapPlatformError.deviceSDCardUnavailable
            }
            let message = bleManager.deviceTransferLastErrorMessage
                .flatMap { $0.isEmpty ? nil : $0 } ?? errorCode
            throw OfflineMapPlatformError.deviceMapTransferRejected(message)
        }
        throw OfflineMapPlatformError.missingTransferBaseURL
    }

    private func freshMapTransferRejection(
        after initialErrorSequence: UInt64?,
        networkError: Error,
        bleManager: BLEManager
    ) async -> OfflineMapPlatformError? {
        guard let platformError = networkError as? OfflineMapPlatformError,
              case .transferServerProbeFailed = platformError
        else { return nil }

        if let rejection = currentMapTransferRejection(
            after: initialErrorSequence,
            bleManager: bleManager
        ) {
            return rejection
        }

        let initialStatusRevision = bleManager.deviceTransferStatusRevision
        guard bleManager.requestDeviceTransferStatus() else { return nil }
        for _ in 0..<8 {
            if Task.isCancelled { return nil }
            try? await Task.sleep(
                nanoseconds:
                    DeviceTransferHandshakePolicy.retryIntervalNanoseconds
            )
            if bleManager.deviceTransferStatusRevision !=
                    initialStatusRevision,
               let rejection = currentMapTransferRejection(
                    after: initialErrorSequence,
                    bleManager: bleManager
               ) {
                return rejection
            }
        }
        return nil
    }

    private func currentMapTransferRejection(
        after initialErrorSequence: UInt64?,
        bleManager: BLEManager
    ) -> OfflineMapPlatformError? {
        guard let failure = DeviceTransferFreshFailurePolicy.failure(
            after: initialErrorSequence,
            currentSequence: bleManager.deviceTransferLastErrorSequence,
            code: bleManager.deviceTransferLastErrorCode,
            message: bleManager.deviceTransferLastErrorMessage
        ) else { return nil }
        if failure.code == "sd_unavailable" {
            return .deviceSDCardUnavailable
        }
        return .deviceMapTransferRejected(failure.message)
    }

    func exitMapTransfer(bleManager: BLEManager) async {
        if bleManager.requestMapTransferMode(enabled: false) {
            _ = await bleManager.waitForNavigationWritesToDrain(timeoutSeconds: 2)
        }
        removeJoinedAccessPointIfNeeded()
        record(mode: .map, event: "transfer_exited")
    }

    func enterFirmwareTransfer(
        bleManager: BLEManager,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> DeviceTransferSession {
        record(mode: .firmware, event: "transfer_requested")
        status("requesting firmware transfer mode")
        guard bleManager.isNavigationReady else {
            throw FirmwareUpdateError.deviceNotReady
        }
        let initialDeviceTransferStatusRevision =
            bleManager.deviceTransferStatusRevision

        guard bleManager.requestDeviceTransferMode(.firmware) else {
            throw FirmwareUpdateError.transferCommandNotSent
        }

        for attempt in 0..<DeviceTransferHandshakePolicy.attemptCount {
            if bleManager.deviceTransferStatusRevision !=
                   initialDeviceTransferStatusRevision,
               let session = try secureSession(
                mode: .firmware,
                bleManager: bleManager
               ) {
                do {
                    try await joinDeviceNetworkIfNeeded(
                        session: session,
                        statusPath: "firmware-update/status",
                        status: status
                    )
                } catch {
                    exitFirmwareTransfer(bleManager: bleManager)
                    throw error
                }
                record(
                    mode: .firmware,
                    event: "transfer_ready",
                    fields: [
                        "networkTransport": session.networkTransport ?? "unknown",
                        "fallback": String(session.hotspotFallback),
                    ]
                )
                return session
            }
            if DeviceTransferHandshakePolicy.shouldRequestStatus(
                attempt: attempt
            ) {
                _ = bleManager.requestDeviceTransferStatus()
            }
            try await Task.sleep(
                nanoseconds:
                    DeviceTransferHandshakePolicy.retryIntervalNanoseconds
            )
        }
        throw FirmwareUpdateError.missingTransferSession
    }

    func exitFirmwareTransfer(bleManager: BLEManager) {
        bleManager.requestDeviceTransferExit()
        removeJoinedAccessPointIfNeeded()
        record(mode: .firmware, event: "transfer_exited")
    }

    func enterDiagnostics(
        bleManager: BLEManager,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> DeviceTransferSession {
        record(mode: .diagnostics, event: "transfer_requested")
        status("requesting device diagnostics")
        guard bleManager.isNavigationReady else {
            throw RemoteDeviceDebugError.deviceNotReady
        }
        guard bleManager.supportsRideDiagnostics else {
            throw RemoteDeviceDebugError.unsupportedFirmware
        }
        var enterWasQueued = false
        let lanCredentials = RemoteDebugLANCredentialStore().load()
        do {
            let initialRevision = bleManager.deviceTransferStatusRevision
            guard bleManager.requestDeviceTransferMode(
                .diagnostics,
                remoteDebugLANCredentials: lanCredentials
            ) else {
                throw RemoteDeviceDebugError.transferCommandNotSent
            }
            enterWasQueued = true
            let attemptCount = DeviceTransferHandshakePolicy
                .diagnosticsAttemptCount(lanFirst: lanCredentials != nil)
            var session = try await waitForDiagnosticsSession(
                bleManager: bleManager,
                afterRevision: initialRevision,
                attemptCount: attemptCount
            )
            if session.networkTransport == "lan" {
                status("checking local Wi-Fi")
                let probeResult = try await waitForTransferServer(
                    session: session,
                    statusPath: "device-diagnostics/v1/status",
                    timeout: 4
                )
                if !probeResult.isReady {
                    status("switching to device hotspot")
                    try await stopDiagnostics(bleManager: bleManager)
                    enterWasQueued = false
                    let fallbackRevision = bleManager.deviceTransferStatusRevision
                    guard bleManager.requestDeviceTransferMode(
                        .diagnostics,
                        remoteDebugHotspotFallbackReason: .endpointUnreachable
                    ) else {
                        throw RemoteDeviceDebugError.transferCommandNotSent
                    }
                    enterWasQueued = true
                    session = try await waitForDiagnosticsSession(
                        bleManager: bleManager,
                        afterRevision: fallbackRevision,
                        attemptCount: DeviceTransferHandshakePolicy.attemptCount
                    )
                }
            }
            try await joinDeviceNetworkIfNeeded(
                session: session,
                statusPath: "device-diagnostics/v1/status",
                status: status
            )
            record(
                mode: .diagnostics,
                event: "transfer_ready",
                fields: [
                    "networkTransport": session.networkTransport ?? "unknown",
                    "fallback": String(session.hotspotFallback),
                ]
            )
            return session
        } catch {
            let rejectedBeforeSession: Bool
            if let remoteError = error as? RemoteDeviceDebugError,
               case .rejected = remoteError {
                rejectedBeforeSession =
                    bleManager.deviceTransferMode !=
                    DeviceTransferSession.Mode.diagnostics.rawValue
            } else {
                rejectedBeforeSession = false
            }
            if enterWasQueued && !rejectedBeforeSession {
                // An unstructured task does not inherit cancellation from the
                // failed entry attempt. Await its bounded exit handshake so a
                // cancel during status/LAN/hotspot setup cannot strand the
                // device in diagnostics mode or leave the joined AP behind.
                // A fresh firmware rejection while no diagnostics session is
                // active needs no cleanup; returning it immediately preserves
                // the fail-fast contract and its original error code.
                let cleanup = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await self.exitDiagnostics(bleManager: bleManager)
                }
                await cleanup.value
            }
            throw error
        }
    }

    private func waitForDiagnosticsSession(
        bleManager: BLEManager,
        afterRevision initialRevision: UInt64,
        attemptCount: Int
    ) async throws -> DeviceTransferSession {
        for attempt in 0..<attemptCount {
            if bleManager.deviceTransferStatusRevision != initialRevision,
               let session = try secureSession(
                mode: .diagnostics,
                bleManager: bleManager
               ) {
                return session
            }
            // A fresh firmware rejection is authoritative. Do not spend the
            // remainder of the LAN/hotspot readiness window polling after the
            // device has already classified storage or seal preparation.
            if bleManager.deviceTransferStatusRevision != initialRevision,
               let code = bleManager.deviceTransferLastErrorCode,
               !code.isEmpty {
                let fallback = bleManager.deviceTransferLastErrorMessage
                    .flatMap { $0.isEmpty ? nil : $0 }
                throw RemoteDeviceDebugError.rejected(
                    code: code,
                    message: DeviceDiagnosticsRejectionPolicy.message(
                        code: code,
                        fallback: fallback
                    )
                )
            }
            if DeviceTransferHandshakePolicy.shouldRequestStatus(attempt: attempt) {
                _ = bleManager.requestDeviceTransferStatus()
            }
            try await Task.sleep(
                nanoseconds: DeviceTransferHandshakePolicy.retryIntervalNanoseconds
            )
        }
        if bleManager.deviceTransferStatusRevision != initialRevision,
           let code = bleManager.deviceTransferLastErrorCode,
           !code.isEmpty {
            let fallback = bleManager.deviceTransferLastErrorMessage
                .flatMap { $0.isEmpty ? nil : $0 }
            throw RemoteDeviceDebugError.rejected(
                code: code,
                message: DeviceDiagnosticsRejectionPolicy.message(
                    code: code,
                    fallback: fallback
                )
            )
        }
        throw RemoteDeviceDebugError.missingSession
    }

#if HOST_TESTING
    func waitForDiagnosticsSessionForTesting(
        bleManager: BLEManager,
        afterRevision initialRevision: UInt64,
        attemptCount: Int
    ) async throws -> DeviceTransferSession {
        try await waitForDiagnosticsSession(
            bleManager: bleManager,
            afterRevision: initialRevision,
            attemptCount: attemptCount
        )
    }
#endif

    private func stopDiagnostics(bleManager: BLEManager) async throws {
        let initialRevision = bleManager.deviceTransferStatusRevision
        guard bleManager.requestDeviceTransferExit() else {
            throw RemoteDeviceDebugError.transferCommandNotSent
        }
        _ = await bleManager.waitForNavigationWritesToDrain(timeoutSeconds: 2)
        for attempt in 0..<DeviceTransferHandshakePolicy.remoteDebugExitAttemptCount {
            if bleManager.deviceTransferStatusRevision != initialRevision,
               bleManager.deviceTransferMode.isEmpty,
               bleManager.deviceTransferSessionToken?.isEmpty != false {
                return
            }
            if DeviceTransferHandshakePolicy.shouldRequestStatus(attempt: attempt) {
                _ = bleManager.requestDeviceTransferStatus()
            }
            try await Task.sleep(
                nanoseconds: DeviceTransferHandshakePolicy.retryIntervalNanoseconds
            )
        }
        throw RemoteDeviceDebugError.rejected(
            code: "diagnostics_exit_unconfirmed",
            message: "The device did not confirm that the diagnostics session ended."
        )
    }

    func exitDiagnostics(bleManager: BLEManager) async throws {
        defer { removeJoinedAccessPointIfNeeded() }
        try await stopDiagnostics(bleManager: bleManager)
        record(mode: .diagnostics, event: "transfer_exited")
    }

    func enterRemoteDebug(
        bleManager: BLEManager,
        lanCredentials: RemoteDebugLANCredentials? = nil,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> DeviceTransferSession {
        record(mode: .debug, event: "transfer_requested")
        status(lanCredentials == nil
            ? "requesting device hotspot"
            : "trying local Wi-Fi")
        guard bleManager.isNavigationReady else {
            throw RemoteDeviceDebugError.deviceNotReady
        }
        guard bleManager.supportsRemoteDeviceDebug else {
            throw RemoteDeviceDebugError.unsupportedFirmware
        }
        var enterWasQueued = false
        do {
            let initialRevision = bleManager.deviceTransferStatusRevision
            guard bleManager.requestDeviceTransferMode(
                .debug,
                remoteDebugLANCredentials: lanCredentials
            ) else {
                throw RemoteDeviceDebugError.transferCommandNotSent
            }
            enterWasQueued = true

            let session = try await waitForRemoteDebugSession(
                bleManager: bleManager,
                afterRevision: initialRevision
            )
            if session.networkTransport == "lan" {
                // The browser can run on a different computer. The ESP's
                // authenticated BLE status is authoritative that it joined
                // the LAN and published the debug endpoint; the iPhone's own
                // route must not tear down a session another LAN client can
                // already reach.
                status("local Wi-Fi ready")
                record(
                    mode: .debug,
                    event: "transfer_ready",
                    fields: [
                        "networkTransport": session.networkTransport ?? "unknown",
                        "fallback": String(session.hotspotFallback),
                    ]
                )
                return session
            }
            status(session.hotspotFallback
                ? "device hotspot fallback ready"
                : "remote debug session ready")
            record(
                mode: .debug,
                event: "transfer_ready",
                fields: [
                    "networkTransport": session.networkTransport ?? "unknown",
                    "fallback": String(session.hotspotFallback),
                ]
            )
            return session
        } catch {
            // The enter command may already be running even when its status
            // acknowledgement is lost. Queue a compensating exit on every
            // post-enqueue failure; a cancelled task may skip the polling but
            // the command itself is still delivered by the write queue.
            if enterWasQueued {
                try? await exitRemoteDebug(bleManager: bleManager)
            }
            throw error
        }
    }

    private func waitForRemoteDebugSession(
        bleManager: BLEManager,
        afterRevision initialRevision: UInt64
    ) async throws -> DeviceTransferSession {
        for attempt in 0..<DeviceTransferHandshakePolicy.remoteDebugAttemptCount {
            if bleManager.deviceTransferStatusRevision != initialRevision,
               let session = try secureSession(
                mode: .debug,
                bleManager: bleManager
               ) {
                return session
            }
            if DeviceTransferHandshakePolicy.shouldRequestStatus(attempt: attempt) {
                _ = bleManager.requestDeviceTransferStatus()
            }
            try await Task.sleep(
                nanoseconds: DeviceTransferHandshakePolicy.retryIntervalNanoseconds
            )
        }
        if bleManager.deviceTransferStatusRevision != initialRevision,
           let code = bleManager.deviceTransferLastErrorCode,
           !code.isEmpty {
            let message = bleManager.deviceTransferLastErrorMessage
                .flatMap { $0.isEmpty ? nil : $0 } ?? code
            throw RemoteDeviceDebugError.rejected(
                code: code,
                message: message
            )
        }
        throw RemoteDeviceDebugError.missingSession
    }

    func exitRemoteDebug(bleManager: BLEManager) async throws {
        let initialRevision = bleManager.deviceTransferStatusRevision
        guard bleManager.requestDeviceTransferExit() else {
            throw RemoteDeviceDebugError.transferCommandNotSent
        }
        _ = await bleManager.waitForNavigationWritesToDrain(timeoutSeconds: 2)
        for attempt in 0..<DeviceTransferHandshakePolicy.remoteDebugExitAttemptCount {
            if bleManager.deviceTransferStatusRevision != initialRevision,
               bleManager.deviceTransferMode.isEmpty,
               bleManager.deviceTransferSessionToken?.isEmpty != false {
                return
            }
            if DeviceTransferHandshakePolicy.shouldRequestStatus(attempt: attempt) {
                _ = bleManager.requestDeviceTransferStatus()
            }
            try await Task.sleep(
                nanoseconds: DeviceTransferHandshakePolicy.retryIntervalNanoseconds
            )
        }
        throw RemoteDeviceDebugError.rejected(
            code: "debug_exit_unconfirmed",
            message: "The device did not confirm that the debug session ended."
        )
    }

    private func joinDeviceNetworkIfNeeded(
        session: DeviceTransferSession,
        statusPath: String,
        status: @escaping @MainActor (String) -> Void
    ) async throws {
        guard session.baseURL.host == "192.168.4.1",
              let ssid = session.accessPointSSID,
              !ssid.isEmpty else {
            return
        }

#if os(iOS)
        let initialNetworkObservation = await currentNetworkObservation(
            expectedSSID: ssid
        )
        if initialNetworkObservation == .target {
            joinedAccessPointSSID = ssid
            status("checking device transfer server")
            let result = try await waitForTransferServer(
                session: session,
                statusPath: statusPath,
                networkObservation: initialNetworkObservation
            )
            if result.isReady {
                return
            }
            throw OfflineMapPlatformError.transferServerProbeFailed(
                ssid,
                result.diagnosticMessage(
                    networkObservation: initialNetworkObservation
                )
            )
        }

        status("joining device Wi-Fi")
        var lastApplyError: NSError?
        var lastDiagnostic: String?
        var lastFailureWasServerProbe = false

        // Clear a saved configuration before the first bounded association
        // attempt. An accepted configuration gets a complete association and
        // pinned-probe window before one fresh application is allowed. Never
        // re-prompt after user, policy, or validation denial.
        Self.removeAccessoryNetworkConfiguration(ssid: ssid)
        try await Task.sleep(
            nanoseconds:
                DeviceNetworkJoinPolicy.configurationSettleDelayNanoseconds
        )

        for attempt in 0..<DeviceNetworkJoinPolicy.applyAttemptCount {
            lastFailureWasServerProbe = false
            let configuration = DeviceNetworkJoinPolicy.hotspotConfiguration(
                ssid: ssid,
                passphrase: session.accessPointPassphrase
            )
            // A join-once network is disconnected by iOS when the screen sleeps
            // or the app remains backgrounded for 15 seconds. Keep this
            // accessory AP configured for the background URLSession upload and
            // remove it explicitly when transfer mode exits.
            configuration.joinOnce = false
            configuration.lifeTimeInDays = 1

            let applyError = await apply(configuration: configuration)
            lastApplyError = applyError
            var associationAccepted = applyError == nil

            if let applyError {
                print(
                    "Device Wi-Fi apply failed: " +
                    DeviceNetworkJoinPolicy.diagnosticMessage(
                        domain: applyError.domain,
                        code: applyError.code,
                        message: applyError.localizedDescription
                    )
                )
                let alreadyAssociated =
                    DeviceNetworkJoinPolicy.isAlreadyAssociated(
                        domain: applyError.domain,
                        code: applyError.code,
                        message: applyError.localizedDescription
                    )
                if alreadyAssociated {
                    associationAccepted = true
                }
            }

            let networkObservation: DeviceTransferNetworkObservation
            if associationAccepted {
                networkObservation = try await waitForNetworkObservation(
                    expectedSSID: ssid,
                    timeout:
                        DeviceNetworkJoinPolicy.associationObservationTimeout
                )
            } else {
                // A configuration error can race with an already-completed
                // association. Observe the active network once before deciding
                // whether the typed apply error is terminal.
                networkObservation = await currentNetworkObservation(
                    expectedSSID: ssid
                )
            }
            var observationFields = [
                "attempt": String(attempt + 1),
                "result": networkObservation.rawValue,
                "applyResult": applyError == nil ? "accepted" : "error",
            ]
            if let applyError {
                observationFields["applyErrorDomain"] = applyError.domain
                observationFields["applyErrorCode"] = String(applyError.code)
            }
            record(
                mode: session.mode,
                event: "wifi_observation",
                fields: observationFields
            )

            if networkObservation == .other {
                lastDiagnostic =
                    "accessory Wi-Fi association was not confirmed"
                lastApplyError = nil
            } else if associationAccepted || networkObservation == .target {
                joinedAccessPointSSID = ssid
                status("waiting for device transfer server")
                let result = try await waitForTransferServer(
                    session: session,
                    statusPath: statusPath,
                    networkObservation: networkObservation
                )
                if result.isReady {
                    print("Device Wi-Fi ready: \(ssid)")
                    return
                }
                lastApplyError = nil
                lastDiagnostic = result.diagnosticMessage(
                    networkObservation: networkObservation
                )
                lastFailureWasServerProbe = true
                if !result.shouldRetry || networkObservation == .target {
                    break
                }
            } else if let applyError,
                      !DeviceNetworkJoinPolicy.shouldRetry(
                        domain: applyError.domain,
                        code: applyError.code
                      ) {
                break
            }

            if DeviceNetworkJoinPolicy.hasAnotherAssociationAttempt(
                after: attempt
            ) {
                status("retrying device Wi-Fi")
                Self.removeAccessoryNetworkConfiguration(ssid: ssid)
                joinedAccessPointSSID = nil
                try await Task.sleep(
                    nanoseconds:
                        DeviceNetworkJoinPolicy.configurationSettleDelayNanoseconds
                )
            }
        }

        Self.removeAccessoryNetworkConfiguration(ssid: ssid)
        joinedAccessPointSSID = nil
        let diagnostic = lastApplyError.map {
            DeviceNetworkJoinPolicy.diagnosticMessage(
                domain: $0.domain,
                code: $0.code,
                message: $0.localizedDescription
            )
        } ?? lastDiagnostic ??
            "no authenticated pinned HTTP 200 before the deadline"
        print("Device Wi-Fi unavailable: \(ssid): \(diagnostic)")
        if lastFailureWasServerProbe {
            throw OfflineMapPlatformError.transferServerProbeFailed(
                ssid,
                diagnostic
            )
        }
        throw OfflineMapPlatformError.transferWiFiJoinFailed(ssid, diagnostic)
#endif
    }

#if os(iOS)
    private func apply(
        configuration: NEHotspotConfiguration
    ) async -> NSError? {
        await withCheckedContinuation { continuation in
            NEHotspotConfigurationManager.shared.apply(configuration) { error in
                continuation.resume(returning: error as NSError?)
            }
        }
    }

    private func currentNetworkObservation(
        expectedSSID: String
    ) async -> DeviceTransferNetworkObservation {
        await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning:
                    DeviceTransferNetworkObservation.classify(
                        currentSSID: network?.ssid,
                        expectedSSID: expectedSSID
                    )
                )
            }
        }
    }

    private func waitForNetworkObservation(
        expectedSSID: String,
        timeout: TimeInterval
    ) async throws -> DeviceTransferNetworkObservation {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var latest = DeviceTransferNetworkObservation.unavailable
        while true {
            latest = await currentNetworkObservation(expectedSSID: expectedSSID)
            if latest == .target ||
                ProcessInfo.processInfo.systemUptime >= deadline {
                return latest
            }
            try await Task.sleep(
                nanoseconds:
                    DeviceNetworkJoinPolicy
                        .associationObservationRetryNanoseconds
            )
        }
    }
#endif

    private func waitForTransferServer(
        session: DeviceTransferSession,
        statusPath: String,
        timeout: TimeInterval? = nil,
        networkObservation: DeviceTransferNetworkObservation = .unavailable
    ) async throws -> DeviceTransferServerProbeResult {
        let absoluteTimeout = max(
            1,
            timeout ?? DeviceTransferServerProbePolicy.absoluteTimeout
        )
        let deadline = ProcessInfo.processInfo.systemUptime + absoluteTimeout
        let diagnostics = DeviceTransferPinnedSessionDiagnostics()
        guard let urlSession = DeviceTransferPinnedSessionFactory.make(
            configuration: DeviceTransferServerProbePolicy
                .makeSessionConfiguration(
                    resourceTimeout: min(
                        DeviceTransferServerProbePolicy.resourceTimeout,
                        absoluteTimeout
                    )
                ),
            baseURL: session.baseURL,
            certificateSHA256: session.tlsCertificateSHA256,
            diagnostics: diagnostics
        ) else {
            let result = DeviceTransferServerProbeResult(
                outcome: .invalidPinnedSession,
                diagnostics: diagnostics.snapshot()
            )
            recordProbe(
                session: session,
                attempt: 1,
                networkObservation: networkObservation,
                result: result
            )
            return result
        }
        defer { urlSession.invalidateAndCancel() }

        var lastResult = DeviceTransferServerProbeResult(
            outcome: .transportError(
                domain: NSURLErrorDomain,
                code: NSURLErrorTimedOut
            ),
            diagnostics: diagnostics.snapshot()
        )
        for attempt in 0..<DeviceTransferServerProbePolicy.maximumAttemptCount {
            let delay = DeviceTransferServerProbePolicy
                .retryDelaysNanoseconds[attempt]
            if delay > 0 {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0,
                      Double(delay) / 1_000_000_000 < remaining else { break }
                try await Task.sleep(nanoseconds: delay)
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }

            diagnostics.reset()
            lastResult = try await probeTransferServer(
                transferSession: session,
                statusPath: statusPath,
                urlSession: urlSession,
                diagnostics: diagnostics,
                requestTimeout: min(
                    DeviceTransferServerProbePolicy.requestTimeout,
                    remaining
                )
            )
            recordProbe(
                session: session,
                attempt: attempt + 1,
                networkObservation: networkObservation,
                result: lastResult
            )
            if lastResult.isReady || !lastResult.shouldRetry {
                return lastResult
            }
        }
        return lastResult
    }

    private func removeJoinedAccessPointIfNeeded() {
#if os(iOS)
        guard let ssid = joinedAccessPointSSID else { return }
        Self.removeAccessoryNetworkConfiguration(ssid: ssid)
        joinedAccessPointSSID = nil
#endif
    }

    nonisolated static func removeAccessoryNetworkConfiguration(ssid: String) {
#if os(iOS)
        guard !ssid.isEmpty else { return }
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
#endif
    }

    private func probeTransferServer(
        transferSession: DeviceTransferSession,
        statusPath: String,
        urlSession: URLSession,
        diagnostics: DeviceTransferPinnedSessionDiagnostics,
        requestTimeout: TimeInterval
    ) async throws -> DeviceTransferServerProbeResult {
        let url = transferSession.baseURL.appendingPathComponent(statusPath)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = requestTimeout
        if let sessionToken = transferSession.sessionToken,
           !sessionToken.isEmpty {
            request.setValue(
                sessionToken,
                forHTTPHeaderField: "X-BikeComputer-Transfer-Token"
            )
        }

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                return DeviceTransferServerProbeResult(
                    outcome: .invalidResponse,
                    diagnostics: diagnostics.snapshot()
                )
            }
            return DeviceTransferServerProbeResult(
                outcome: response.statusCode == 200
                    ? .ready
                    : .httpStatus(response.statusCode),
                diagnostics: diagnostics.snapshot()
            )
        } catch {
            try Task.checkCancellation()
            let error = error as NSError
            return DeviceTransferServerProbeResult(
                outcome: .transportError(
                    domain: error.domain,
                    code: error.code
                ),
                diagnostics: diagnostics.snapshot()
            )
        }
    }

    private func recordProbe(
        session: DeviceTransferSession,
        attempt: Int,
        networkObservation: DeviceTransferNetworkObservation,
        result: DeviceTransferServerProbeResult
    ) {
        var fields = result.diagnostics.diagnosticFields
        fields["attempt"] = String(attempt)
        fields["networkObservation"] = networkObservation.rawValue
        fields["outcome"] = result.diagnosticCode
        switch result.outcome {
        case .httpStatus(let status):
            fields["httpStatus"] = String(status)
        case .transportError(let domain, let code):
            fields["errorDomain"] = domain
            fields["errorCode"] = String(code)
        case .ready, .invalidPinnedSession, .invalidResponse:
            break
        }
        record(mode: session.mode, event: "server_probe", fields: fields)
        print(
            "Device transfer probe attempt=\(attempt) " +
            "network=\(networkObservation.rawValue) " +
            "outcome=\(result.diagnosticCode)"
        )
    }
}
