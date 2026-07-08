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

@MainActor
final class DeviceTransferManager {
    func enterMapTransfer(
        bleManager: BLEManager,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> DeviceTransferSession {
        status("requesting device transfer mode")
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
                let session = DeviceTransferSession(
                    mode: .map,
                    baseURL: baseURL,
                    accessPointSSID: bleManager.mapTransferAccessPointSSID,
                    sessionToken: bleManager.deviceTransferSessionToken
                )
                await joinDeviceNetworkIfNeeded(session: session,
                                                statusPath: "map-transfer/status",
                                                sessionToken: session.sessionToken,
                                                status: status)
                return session
            }
            if attempt % 4 == 3 {
                bleManager.requestMapTransferStatus()
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw OfflineMapPlatformError.missingTransferBaseURL
    }

    func exitMapTransfer(bleManager: BLEManager) {
        bleManager.requestMapTransferMode(enabled: false)
    }

    func enterFirmwareTransfer(
        bleManager: BLEManager,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> DeviceTransferSession {
        status("requesting firmware transfer mode")
        guard bleManager.isNavigationReady else {
            throw FirmwareUpdateError.deviceNotReady
        }

        guard bleManager.requestDeviceTransferMode(.firmware) else {
            throw FirmwareUpdateError.transferCommandNotSent
        }
        guard bleManager.requestDeviceTransferStatus() else {
            throw FirmwareUpdateError.transferCommandNotSent
        }
        guard await bleManager.waitForNavigationWritesToDrain(timeoutSeconds: 2) else {
            throw FirmwareUpdateError.transferCommandNotSent
        }

        for attempt in 0..<32 {
            if bleManager.deviceTransferMode == DeviceTransferSession.Mode.firmware.rawValue,
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
            if attempt % 4 == 3 {
                bleManager.requestDeviceTransferStatus()
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw FirmwareUpdateError.missingTransferSession
    }

    func exitFirmwareTransfer(bleManager: BLEManager) {
        bleManager.requestDeviceTransferExit()
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
            if await isTransferServerReachable(baseURL: session.baseURL,
                                               statusPath: statusPath,
                                               sessionToken: sessionToken) {
                return
            }
            status("using device Wi-Fi")
            return
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if await isTransferServerReachable(baseURL: session.baseURL,
                                           statusPath: statusPath,
                                           sessionToken: sessionToken) {
            return
        }
        status("using device Wi-Fi")
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
