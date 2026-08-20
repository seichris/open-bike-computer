//
//  DeviceDiagnosticsTransferManager.swift
//  BikeComputer
//

import CryptoKit
import Foundation

struct DeviceDiagnosticsIndex: Codable {
    let schema: Int
    let source: String
    let bootSequence: UInt32
    let activeChunk: UInt32
    let stats: DeviceDiagnosticsStats
    let chunks: [DeviceDiagnosticsChunk]
}

struct DeviceDiagnosticsStats: Codable {
    let enqueued: UInt32
    let written: UInt32
    let dropped: UInt32
    let storageErrors: UInt32
}

struct DeviceDiagnosticsChunk: Codable, Identifiable {
    let bootSequence: UInt32
    let chunk: UInt32
    let bytes: Int
    let sha256: String

    var id: String { "\(bootSequence)-\(chunk)-\(sha256)" }
}

enum DeviceDiagnosticsTransferError: LocalizedError {
    case deviceIdentityUnavailable
    case invalidIndex
    case requestFailed(Int)
    case oversizedChunk
    case hashMismatch
    case malformedChunk

    var errorDescription: String? {
        switch self {
        case .deviceIdentityUnavailable:
            return "The connected bike computer identity is unavailable."
        case .invalidIndex:
            return "The device returned an invalid diagnostics index."
        case .requestFailed(let status):
            return "The device diagnostics request failed (HTTP \(status))."
        case .oversizedChunk:
            return "The device diagnostics chunk exceeded the safety limit."
        case .hashMismatch:
            return "A device diagnostics chunk failed its integrity check."
        case .malformedChunk:
            return "A device diagnostics chunk contained malformed evidence."
        }
    }
}

@MainActor
final class DeviceDiagnosticsTransferManager {
    private let transferManager = DeviceTransferManager()
    private let maximumChunkBytes = 256 * 1024
    private let maximumIndexBytes = 64 * 1024

    private struct JSONLValidation {
        let firstSequence: UInt64
        let lastSequence: UInt64
    }

    func downloadDeviceLogs(
        bleManager: BLEManager,
        recorder: RideDiagnosticsRecorder,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> Int {
        guard let deviceID = bleManager.connectedDeviceID else {
            throw DeviceDiagnosticsTransferError.deviceIdentityUnavailable
        }
        let deviceDigest = recorder.deviceDigest(for: deviceID)
        transferManager.diagnosticsRecorder = recorder
        recorder.record(
            category: .transfer,
            event: "diagnostics_download_started",
            fields: ["mode": DeviceTransferSession.Mode.diagnostics.rawValue]
        )
        let session = try await transferManager.enterDiagnostics(
            bleManager: bleManager,
            status: status
        )
        do {
            status("reading device diagnostics index")
            let indexData = try await request(
                session: session,
                path: "device-diagnostics/v1/index",
                method: "GET",
                maximumBytes: maximumIndexBytes
            )
            let index = try decodeIndex(indexData)
            var imported = 0
            var previousSequenceByBoot: [UInt32: UInt64] = [:]
            let chunks = index.chunks.sorted {
                ($0.bootSequence, $0.chunk) < ($1.bootSequence, $1.chunk)
            }
            for (offset, chunk) in chunks.enumerated() {
                guard chunk.bytes > 0, chunk.bytes <= maximumChunkBytes,
                      chunk.bootSequence > 0,
                      chunk.bootSequence <= index.bootSequence,
                      chunk.chunk > 0,
                      chunk.sha256.count == 64,
                      chunk.sha256.allSatisfy({ $0.isHexDigit }) else {
                    throw DeviceDiagnosticsTransferError.invalidIndex
                }
                let cached = recorder.importedDeviceChunkData(
                    deviceDigest: deviceDigest,
                    bootSequence: chunk.bootSequence,
                    chunk: chunk.chunk,
                    sha256: chunk.sha256
                )
                let existing = cached.flatMap { data -> Data? in
                    guard data.count == chunk.bytes,
                          Self.sha256(data) == chunk.sha256.lowercased(),
                          Self.validateJSONL(data) != nil else {
                        return nil
                    }
                    return data
                }
                let data: Data
                if let existing {
                    data = existing
                } else {
                    status("downloading device chunk \(offset + 1) of \(chunks.count)")
                    data = try await request(
                        session: session,
                        path: "device-diagnostics/v1/chunks/\(chunk.bootSequence)/\(chunk.chunk)",
                        method: "GET",
                        maximumBytes: maximumChunkBytes
                    )
                }
                guard data.count == chunk.bytes, data.count <= maximumChunkBytes else {
                    throw DeviceDiagnosticsTransferError.oversizedChunk
                }
                guard Self.sha256(data) == chunk.sha256.lowercased() else {
                    throw DeviceDiagnosticsTransferError.hashMismatch
                }
                guard let validation = Self.validateJSONL(data) else {
                    throw DeviceDiagnosticsTransferError.malformedChunk
                }
                if let previous = previousSequenceByBoot[chunk.bootSequence],
                   validation.firstSequence <= previous {
                    throw DeviceDiagnosticsTransferError.malformedChunk
                }
                previousSequenceByBoot[chunk.bootSequence] = validation.lastSequence
                if existing == nil {
                    _ = try recorder.importDeviceChunk(
                        deviceDigest: deviceDigest,
                        bootSequence: chunk.bootSequence,
                        chunk: chunk.chunk,
                        data: data,
                        sha256: chunk.sha256,
                        enforceRetention: false
                    )
                    imported += 1
                }
            }
            try recorder.importDeviceRecorderHealth(
                deviceDigest: deviceDigest,
                bootSequence: index.bootSequence,
                data: indexData
            )

            status("closing device diagnostics session")
            await closeSession(session, bleManager: bleManager)
            recorder.record(
                category: .transfer,
                event: "diagnostics_download_completed",
                fields: [
                    "mode": DeviceTransferSession.Mode.diagnostics.rawValue,
                    "importedCount": String(imported),
                ]
            )
            return imported
        } catch {
            try? recorder.enforceRetention()
            await closeSession(session, bleManager: bleManager)
            recorder.record(
                level: .warning,
                category: .transfer,
                event: "diagnostics_download_failed",
                fields: ["reason": "transfer_failed"]
            )
            throw error
        }
    }

    private func closeSession(
        _ session: DeviceTransferSession,
        bleManager: BLEManager
    ) async {
        _ = try? await request(
            session: session,
            path: "device-diagnostics/v1/session/exit",
            method: "POST",
            maximumBytes: 4 * 1024
        )
        await transferManager.exitDiagnostics(bleManager: bleManager)
    }

    private func decodeIndex(_ data: Data) throws -> DeviceDiagnosticsIndex {
        guard let index = try? JSONDecoder().decode(DeviceDiagnosticsIndex.self, from: data),
              index.schema == 1,
              index.source == "firmware",
              index.bootSequence > 0,
              index.activeChunk > 0,
              index.chunks.count <= 256 else {
            throw DeviceDiagnosticsTransferError.invalidIndex
        }
        var chunkKeys: Set<String> = []
        for chunk in index.chunks {
            let key = "\(chunk.bootSequence)-\(chunk.chunk)"
            guard chunk.bytes > 0,
                  chunk.bytes <= maximumChunkBytes,
                  chunk.bootSequence > 0,
                  chunk.bootSequence <= index.bootSequence,
                  chunk.chunk > 0,
                  chunk.sha256.count == 64,
                  chunk.sha256.allSatisfy({ $0.isHexDigit }),
                  (chunk.bootSequence < index.bootSequence ||
                    chunk.chunk < index.activeChunk),
                  chunkKeys.insert(key).inserted else {
                throw DeviceDiagnosticsTransferError.invalidIndex
            }
        }
        return index
    }

    private func request(
        session: DeviceTransferSession,
        path: String,
        method: String,
        maximumBytes: Int
    ) async throws -> Data {
        let url = session.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30
        if let token = session.sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-BikeComputer-Transfer-Token")
        }
        if method == "POST" {
            request.setValue("0", forHTTPHeaderField: "Content-Length")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.connectionProxyDictionary = [:]
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        let urlSession = URLSession(configuration: configuration)
        defer { urlSession.invalidateAndCancel() }
        let (bytes, response) = try await urlSession.bytes(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode,
              200..<300 ~= status else {
            throw DeviceDiagnosticsTransferError.requestFailed(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        let expectedLength = response.expectedContentLength
        guard expectedLength < 0 || expectedLength <= Int64(maximumBytes) else {
            throw DeviceDiagnosticsTransferError.oversizedChunk
        }
        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(Int(expectedLength))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw DeviceDiagnosticsTransferError.oversizedChunk
            }
            data.append(byte)
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validateJSONL(_ data: Data) -> JSONLValidation? {
        guard data.count <= 256 * 1024 else { return nil }
        let fractionalTimeFormatter = ISO8601DateFormatter()
        fractionalTimeFormatter.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        let secondTimeFormatter = ISO8601DateFormatter()
        secondTimeFormatter.formatOptions = [.withInternetDateTime]
        var lines = data.split(
            separator: 0x0a,
            omittingEmptySubsequences: true
        )
        guard !lines.isEmpty else { return nil }
        if data.last != 0x0a,
           let last = lines.last,
           (try? JSONSerialization.jsonObject(with: Data(last))) == nil {
            // A reset can leave only the final JSONL record incomplete. The
            // closed chunk is still useful; middle-line corruption remains a
            // hard failure below.
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }
        var previousSequence: UInt64?
        var firstSequence: UInt64?
        for rawLine in lines {
            guard rawLine.count <= 8 * 1024,
                  let object = try? JSONSerialization.jsonObject(
                    with: Data(rawLine)
                  ) as? [String: Any],
                  Set(object.keys).isSubset(of: Set([
                    "schema", "source", "sequence", "level", "category",
                    "event", "wallTime", "uptimeMs", "processId",
                    "captureId", "fields",
                  ])),
                  !(object["schema"] is Bool),
                  object["schema"] as? Int == 1,
                  object["source"] as? String == "firmware",
                  ["debug", "info", "warning", "error"].contains(
                    object["level"] as? String ?? ""
                  ),
                  ["lifecycle", "boot", "ble", "navigation", "gps",
                   "workout", "rideAutomation", "storage", "map", "power",
                   "transfer", "user", "logger"].contains(
                    object["category"] as? String ?? ""
                  ),
                  let eventName = object["event"] as? String,
                  !eventName.isEmpty,
                  eventName.count <= 64,
                  let sequenceValue = object["sequence"] as? Int,
                  !(object["sequence"] is Bool),
                  sequenceValue >= 0 else {
                return nil
            }
            if let wallTime = object["wallTime"] {
                guard let value = wallTime as? String,
                      fractionalTimeFormatter.date(from: value) != nil ||
                        secondTimeFormatter.date(from: value) != nil else {
                    return nil
                }
            }
            if let uptime = object["uptimeMs"] {
                guard !(uptime is Bool),
                      let value = uptime as? Int,
                      value >= 0 else { return nil }
            }
            for key in ["processId", "captureId"] {
                if let identifier = object[key] {
                    guard let value = identifier as? String,
                          isCanonicalUUID(value) else { return nil }
                }
            }
            if let fieldsValue = object["fields"] {
                guard let fields = fieldsValue as? [String: Any],
                      isPrivacySafe(fields) else { return nil }
            }
            let sequence = UInt64(sequenceValue)
            if let previousSequence, sequence <= previousSequence {
                return nil
            }
            if firstSequence == nil { firstSequence = sequence }
            previousSequence = sequence
        }
        guard let firstSequence, let previousSequence else { return nil }
        return JSONLValidation(
            firstSequence: firstSequence,
            lastSequence: previousSequence
        )
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        guard value.utf8.count == 36,
              let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value.lowercased()
    }

    private static func isPrivacySafe(_ value: Any) -> Bool {
        let forbidden = [
            "latitude", "longitude", "coordinate", "address", "instruction",
            "destination", "password", "credential", "token", "ownerkey",
            "healthkit", "heartrate", "heart_rate", "rawimu", "raw_imu",
            "payload",
        ]
        if let dictionary = value as? [String: Any] {
            guard dictionary.count <= 32 else { return false }
            for (key, child) in dictionary {
                let normalized = key.replacingOccurrences(of: "-", with: "_")
                    .lowercased()
                guard RideDiagnosticsFieldPolicy.isAllowed(key),
                      !(child is [String: Any]),
                      !(child is [Any]),
                      !forbidden.contains(where: { normalized.contains($0) }),
                      isFirmwareFieldTypeValid(key: key, value: child),
                      isPrivacySafe(child) else { return false }
            }
            return true
        }
        if let array = value as? [Any] {
            return array.count <= 32 && array.allSatisfy(isPrivacySafe)
        }
        if let string = value as? String {
            let normalized = string.lowercased()
            return !normalized.contains("bearer ") &&
                !normalized.contains("x-bikecomputer-transfer-token") &&
                string.utf8.count <= 256
        }
        return value is NSNumber || value is NSNull
    }

    private static func isFirmwareFieldTypeValid(key: String, value: Any) -> Bool {
        let numberKeys: Set<String> = [
            "accuracy", "activeStage", "ageMs", "alertMode", "bootSequence",
            "bytes", "chunk", "completedStage", "consecutiveEarlyFailures",
            "decisionSequence", "droppedCount", "eventCount", "firmwareBuild",
            "firstMissingUptimeMs", "importedCount", "lastGapMs",
            "lastMissingUptimeMs", "maximumGapMs", "messageBytes",
            "profileVersion", "resetReason", "rideGeneration",
            "runtimeBootSequence", "sampleCount", "sequence", "sourceHealthMask",
            "storageErrorCount",
        ]
        let booleanKeys: Set<String> = [
            "accuracyAvailable", "active", "autoPauseEnabled", "authorized",
            "available", "background", "clockSynchronized", "diagnosticHold",
            "fallback", "fixValid", "navigating", "pendingControl", "ready",
            "rideDetectionArmed", "routeLoaded", "safeMode", "sessionPresent",
            "simulation", "speedAvailable", "viewingMap", "workoutActive",
        ]
        if numberKeys.contains(key) {
            return value is NSNumber && !(value is Bool)
        }
        if booleanKeys.contains(key) {
            return value is Bool
        }
        return value is String
    }
}
