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

    init(
        mode: Mode,
        baseURL: URL,
        accessPointSSID: String?,
        accessPointPassphrase: String? = nil,
        sessionToken: String?,
        networkTransport: String? = nil,
        networkSSID: String? = nil,
        hotspotFallback: Bool = false,
        hotspotFallbackReason: String? = nil
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
    static let commandPrefix = "enter|debug|lan1|"

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

    var commandPayload: Data {
        let ssidBytes = Data(ssid.utf8)
        let passwordBytes = Data(password.utf8)
        var payload = Data(Self.commandPrefix.utf8)
        payload.append(UInt8(ssidBytes.count))
        payload.append(UInt8(passwordBytes.count))
        payload.append(ssidBytes)
        payload.append(passwordBytes)
        return payload
    }
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

enum RemoteDeviceDebugError: LocalizedError, Equatable {
    case deviceNotReady
    case unsupportedFirmware
    case transferCommandNotSent
    case rejected(String)
    case missingSession

    var errorDescription: String? {
        switch self {
        case .deviceNotReady:
            return "The Bike Computer is not authenticated and ready."
        case .unsupportedFirmware:
            return "The connected firmware does not support remote device debugging."
        case .transferCommandNotSent:
            return "The remote-debug request could not be sent."
        case .rejected(let message):
            return message
        case .missingSession:
            return "The device did not return a fresh remote-debug session."
        }
    }
}

enum RemoteDeviceDebugSessionPolicy {
    static func browserURL(for session: DeviceTransferSession) -> URL? {
        guard session.mode == .debug,
              let token = session.sessionToken,
              !token.isEmpty else { return nil }
        let pageURL = session.baseURL
            .appendingPathComponent("device-debug", isDirectory: true)
        guard var components = URLComponents(
            url: pageURL,
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.fragment = token
        return components.url
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
    static let lanReachabilityTimeout: TimeInterval = 4
    static let remoteDebugExitAttemptCount = 32

    static func shouldRequestStatus(attempt: Int) -> Bool {
        attempt > 0 && attempt % 4 == 0
    }

    static func shouldRequestLegacyMapEnter(attempt: Int) -> Bool {
        // A generic DTRN-aware device responds to the enter command itself.
        // Give that application-level acknowledgement two seconds before
        // trying the pre-DTRN map-control command for older firmware.
        attempt == 8
    }
}

enum DeviceNetworkJoinPolicy {
    static let applyAttemptCount = 2
    static let configurationSettleDelayNanoseconds: UInt64 = 500_000_000
    // iOS can take more than the hotspot configuration callback to move from
    // an internet-connected network to a local-only accessory AP. Keep one
    // accepted configuration stable while that association settles; removing
    // and reapplying it here can restart the switch indefinitely.
    static let reachabilityTimeout: TimeInterval = 30
    static let reachabilityRetryNanoseconds: UInt64 = 250_000_000
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

    static func diagnosticMessage(
        domain: String,
        code: Int,
        message: String
    ) -> String {
        "\(message) [\(domain) \(code)]"
    }
}

@MainActor
final class DeviceTransferManager {
    private var joinedAccessPointSSID: String?

    func enterMapTransfer(
        bleManager: BLEManager,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> DeviceTransferSession {
        status("requesting device transfer mode")
        guard bleManager.isNavigationReady else {
            throw OfflineMapPlatformError.missingTransferBaseURL
        }
        let initialDeviceTransferStatusRevision =
            bleManager.deviceTransferStatusRevision

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
               bleManager.deviceTransferMode == DeviceTransferSession.Mode.map.rawValue,
               let baseURL = bleManager.deviceTransferBaseURL,
               let token = bleManager.deviceTransferSessionToken,
               !token.isEmpty {
                let session = DeviceTransferSession(
                    mode: .map,
                    baseURL: baseURL,
                    accessPointSSID: bleManager.deviceTransferAccessPointSSID ??
                        bleManager.mapTransferAccessPointSSID,
                    sessionToken: token
                )
                do {
                    try await joinDeviceNetworkIfNeeded(
                        session: session,
                        statusPath: "map-transfer/status",
                        sessionToken: session.sessionToken,
                        status: status
                    )
                } catch {
                    await exitMapTransfer(bleManager: bleManager)
                    throw error
                }
                return session
            }
            if DeviceTransferHandshakePolicy.shouldRequestLegacyMapEnter(
                attempt: attempt
            ) {
                // Compatibility only: firmware predating generic DTRN map
                // mode needs the legacy MTRN command plus an explicit DSTS
                // request. Current firmware never takes this path because its
                // fresh DSTS response wins above.
                _ = bleManager.requestMapTransferMode(enabled: true)
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

    func exitMapTransfer(bleManager: BLEManager) async {
        if bleManager.requestMapTransferMode(enabled: false) {
            _ = await bleManager.waitForNavigationWritesToDrain(timeoutSeconds: 2)
        }
        removeJoinedAccessPointIfNeeded()
    }

    func enterFirmwareTransfer(
        bleManager: BLEManager,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> DeviceTransferSession {
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
               bleManager.deviceTransferMode == DeviceTransferSession.Mode.firmware.rawValue,
               let baseURL = bleManager.deviceTransferBaseURL,
               let token = bleManager.deviceTransferSessionToken,
               !token.isEmpty {
                let session = DeviceTransferSession(
                    mode: .firmware,
                    baseURL: baseURL,
                    accessPointSSID: bleManager.deviceTransferAccessPointSSID,
                    sessionToken: token
                )
                do {
                    try await joinDeviceNetworkIfNeeded(
                        session: session,
                        statusPath: "firmware-update/status",
                        sessionToken: session.sessionToken,
                        status: status
                    )
                } catch {
                    exitFirmwareTransfer(bleManager: bleManager)
                    throw error
                }
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
    }

    func enterRemoteDebug(
        bleManager: BLEManager,
        lanCredentials: RemoteDebugLANCredentials? = nil,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> DeviceTransferSession {
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

            var session = try await waitForRemoteDebugSession(
                bleManager: bleManager,
                afterRevision: initialRevision
            )
            if session.networkTransport == "lan" {
                status("verifying local Wi-Fi")
                if try await waitForTransferServer(
                    baseURL: session.baseURL,
                    statusPath: "device-debug/v1/info",
                    sessionToken: session.sessionToken,
                    timeout: DeviceTransferHandshakePolicy.lanReachabilityTimeout
                ) {
                    status("local Wi-Fi ready")
                    return session
                }

                status("local Wi-Fi unreachable; starting device hotspot")
                session = try await restartRemoteDebugOnHotspot(
                    bleManager: bleManager
                )
            }
            status(session.hotspotFallback
                ? "device hotspot fallback ready"
                : "remote debug session ready")
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
               bleManager.deviceTransferMode == DeviceTransferSession.Mode.debug.rawValue,
               let baseURL = bleManager.deviceTransferBaseURL,
               let token = bleManager.deviceTransferSessionToken,
               !token.isEmpty {
                return DeviceTransferSession(
                    mode: .debug,
                    baseURL: baseURL,
                    accessPointSSID: bleManager.deviceTransferAccessPointSSID,
                    accessPointPassphrase: bleManager.deviceTransferAccessPointPassphrase,
                    sessionToken: token,
                    networkTransport: bleManager.deviceTransferNetworkTransport,
                    networkSSID: bleManager.deviceTransferNetworkSSID,
                    hotspotFallback: bleManager.deviceTransferUsedHotspotFallback,
                    hotspotFallbackReason: bleManager.deviceTransferHotspotFallbackReason
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
            let message = bleManager.deviceTransferLastErrorMessage
                .flatMap { $0.isEmpty ? nil : $0 } ?? code
            throw RemoteDeviceDebugError.rejected(message)
        }
        throw RemoteDeviceDebugError.missingSession
    }

    private func restartRemoteDebugOnHotspot(
        bleManager: BLEManager
    ) async throws -> DeviceTransferSession {
        try await exitRemoteDebug(bleManager: bleManager)

        let fallbackRevision = bleManager.deviceTransferStatusRevision
        guard bleManager.requestDeviceTransferMode(
            .debug,
            remoteDebugHotspotFallbackReason: .endpointUnreachable
        ) else {
            throw RemoteDeviceDebugError.transferCommandNotSent
        }
        return try await waitForRemoteDebugSession(
            bleManager: bleManager,
            afterRevision: fallbackRevision
        )
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
            "The device did not confirm that the debug session ended."
        )
    }

    private func joinDeviceNetworkIfNeeded(
        session: DeviceTransferSession,
        statusPath: String,
        sessionToken: String?,
        status: @escaping @MainActor (String) -> Void
    ) async throws {
        guard session.baseURL.host == "192.168.4.1",
              let ssid = session.accessPointSSID,
              !ssid.isEmpty else {
            return
        }

#if os(iOS)
        if await isTransferServerReachable(
            baseURL: session.baseURL,
            statusPath: statusPath,
            sessionToken: sessionToken
        ) {
            joinedAccessPointSSID = ssid
            return
        }

        status("joining device Wi-Fi")
        var lastApplyError: NSError?
        var associationAccepted = false

        // Clear a saved configuration once before joining. After iOS accepts
        // the replacement, leave it installed until the transfer finishes so
        // the system has one uninterrupted local-only association window.
        Self.removeAccessoryNetworkConfiguration(ssid: ssid)
        try await Task.sleep(
            nanoseconds:
                DeviceNetworkJoinPolicy.configurationSettleDelayNanoseconds
        )

        for attempt in 0..<DeviceNetworkJoinPolicy.applyAttemptCount {
            let configuration = NEHotspotConfiguration(ssid: ssid)
            // A join-once network is disconnected by iOS when the screen sleeps
            // or the app remains backgrounded for 15 seconds. Keep this
            // accessory AP configured for the background URLSession upload and
            // remove it explicitly when transfer mode exits.
            configuration.joinOnce = false
            configuration.lifeTimeInDays = 1

            let applyError = await apply(configuration: configuration)
            lastApplyError = applyError
            if applyError == nil {
                associationAccepted = true
                break
            }

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
                    break
                }

                // A configuration error can race with a successful
                // association. Preserve a server that is already reachable
                // instead of tearing its network configuration back down.
                if await isTransferServerReachable(
                    baseURL: session.baseURL,
                    statusPath: statusPath,
                    sessionToken: sessionToken
                ) {
                    associationAccepted = true
                    break
                }

                if !DeviceNetworkJoinPolicy.shouldRetry(
                       domain: applyError.domain,
                       code: applyError.code
                   ) {
                    break
                }
            }

            if attempt + 1 < DeviceNetworkJoinPolicy.applyAttemptCount {
                status("retrying device Wi-Fi")
                Self.removeAccessoryNetworkConfiguration(ssid: ssid)
                try await Task.sleep(
                    nanoseconds:
                        DeviceNetworkJoinPolicy.configurationSettleDelayNanoseconds
                )
            }
        }

        if associationAccepted {
            joinedAccessPointSSID = ssid
            status("waiting for device transfer server")
            if try await waitForTransferServer(
                baseURL: session.baseURL,
                statusPath: statusPath,
                sessionToken: sessionToken
            ) {
                print("Device Wi-Fi ready: \(ssid)")
                return
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
        } ?? "accessory network joined but its transfer server was unreachable"
        print("Device Wi-Fi unavailable: \(ssid): \(diagnostic)")
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
#endif

    private func waitForTransferServer(
        baseURL: URL,
        statusPath: String,
        sessionToken: String?,
        timeout: TimeInterval? = nil
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(
            timeout ?? DeviceNetworkJoinPolicy.reachabilityTimeout
        )
        while true {
            if await isTransferServerReachable(
                baseURL: baseURL,
                statusPath: statusPath,
                sessionToken: sessionToken
            ) {
                return true
            }
            guard Date() < deadline else {
                return false
            }
            try await Task.sleep(
                nanoseconds:
                    DeviceNetworkJoinPolicy.reachabilityRetryNanoseconds
            )
        }
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

    private func isTransferServerReachable(baseURL: URL,
                                           statusPath: String,
                                           sessionToken: String?) async -> Bool {
        let url = baseURL.appendingPathComponent(statusPath)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 1
        if let sessionToken, !sessionToken.isEmpty {
            request.setValue(sessionToken, forHTTPHeaderField: "X-BikeComputer-Transfer-Token")
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
