//
//  DeviceTransferManager.swift
//  BikeComputer
//
//  Shared setup for BLE-controlled local Wi-Fi transfers.
//

import Foundation
#if os(iOS)
import NetworkExtension
#endif

struct DeviceTransferSession: Equatable {
    enum Mode: String, Equatable {
        case map
        case firmware
    }

    let mode: Mode
    let baseURL: URL
    let accessPointSSID: String?
    let sessionToken: String?
}

enum DeviceTransferHandshakePolicy {
    static let attemptCount = 32
    static let retryIntervalNanoseconds: UInt64 = 250_000_000

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
                await joinDeviceNetworkIfNeeded(session: session,
                                                statusPath: "map-transfer/status",
                                                sessionToken: session.sessionToken,
                                                status: status)
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
                await joinDeviceNetworkIfNeeded(session: session,
                                                statusPath: "firmware-update/status",
                                                sessionToken: session.sessionToken,
                                                status: status)
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

    private func joinDeviceNetworkIfNeeded(
        session: DeviceTransferSession,
        statusPath: String,
        sessionToken: String?,
        status: @escaping @MainActor (String) -> Void
    ) async {
        guard session.baseURL.host == "192.168.4.1",
              let ssid = session.accessPointSSID,
              !ssid.isEmpty else {
            return
        }

#if os(iOS)
        status("joining device Wi-Fi")
        let configuration = NEHotspotConfiguration(ssid: ssid)
        // A join-once network is disconnected by iOS when the screen sleeps or
        // the app remains backgrounded for 15 seconds. Keep this accessory AP
        // configured for the duration of the background URLSession upload and
        // remove it explicitly when transfer mode exits.
        configuration.joinOnce = false
        configuration.lifeTimeInDays = 1

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
            joinedAccessPointSSID = ssid
        } catch {
            if await isTransferServerReachable(baseURL: session.baseURL,
                                               statusPath: statusPath,
                                               sessionToken: sessionToken) {
                joinedAccessPointSSID = ssid
                return
            }
            status("using device Wi-Fi")
            return
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if await isTransferServerReachable(baseURL: session.baseURL,
                                           statusPath: statusPath,
                                           sessionToken: sessionToken) {
            joinedAccessPointSSID = ssid
            return
        }
        status("using device Wi-Fi")
#endif
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
        request.timeoutInterval = 3
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
