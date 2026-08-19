//
//  DeviceDiagnosticsTransferManager.swift
//  BikeComputer
//

import CryptoKit
import Foundation

struct DeviceDiagnosticsIndex: Decodable {
    let schema: Int
    let source: String
    let bootSequence: UInt32
    let activeChunk: UInt32
    let chunks: [DeviceDiagnosticsChunk]
}

struct DeviceDiagnosticsChunk: Decodable, Identifiable {
    let bootSequence: UInt32
    let chunk: UInt32
    let bytes: Int
    let sha256: String

    var id: String { "\(bootSequence)-\(chunk)-\(sha256)" }
}

enum DeviceDiagnosticsTransferError: LocalizedError {
    case invalidIndex
    case requestFailed(Int)
    case oversizedChunk
    case hashMismatch
    case malformedChunk

    var errorDescription: String? {
        switch self {
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
    private let maximumChunkBytes = 12 * 1024 * 1024

    func downloadDeviceLogs(
        bleManager: BLEManager,
        recorder: RideDiagnosticsRecorder,
        status: @escaping @MainActor (String) -> Void
    ) async throws -> Int {
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
        var exited = false
        defer {
            if !exited {
                Task { @MainActor in
                    await self.transferManager.exitDiagnostics(bleManager: bleManager)
                }
            }
        }

        status("reading device diagnostics index")
        let indexData = try await request(
            session: session,
            path: "device-diagnostics/v1/index",
            method: "GET"
        )
        let index = try decodeIndex(indexData)
        var imported = 0
        let chunks = index.chunks.sorted {
            ($0.bootSequence, $0.chunk) < ($1.bootSequence, $1.chunk)
        }
        for (offset, chunk) in chunks.enumerated() {
            guard chunk.bytes >= 0, chunk.bytes <= maximumChunkBytes,
                  chunk.bootSequence > 0,
                  chunk.bootSequence <= index.bootSequence,
                  chunk.chunk > 0,
                  chunk.sha256.count == 64,
                  chunk.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw DeviceDiagnosticsTransferError.invalidIndex
            }
            if recorder.hasImportedDeviceChunk(
                bootSequence: chunk.bootSequence,
                chunk: chunk.chunk,
                sha256: chunk.sha256
            ) {
                continue
            }
            status("downloading device chunk \(offset + 1) of \(chunks.count)")
            let data = try await request(
                session: session,
                path: "device-diagnostics/v1/chunks/\(chunk.bootSequence)/\(chunk.chunk)",
                method: "GET"
            )
            guard data.count == chunk.bytes, data.count <= maximumChunkBytes else {
                throw DeviceDiagnosticsTransferError.oversizedChunk
            }
            guard Self.sha256(data) == chunk.sha256.lowercased() else {
                throw DeviceDiagnosticsTransferError.hashMismatch
            }
            guard Self.isValidJSONL(data) else {
                throw DeviceDiagnosticsTransferError.malformedChunk
            }
            _ = try recorder.importDeviceChunk(
                bootSequence: chunk.bootSequence,
                chunk: chunk.chunk,
                data: data,
                sha256: chunk.sha256
            )
            imported += 1
        }

        status("closing device diagnostics session")
        _ = try? await request(
            session: session,
            path: "device-diagnostics/v1/session/exit",
            method: "POST"
        )
        await transferManager.exitDiagnostics(bleManager: bleManager)
        exited = true
        recorder.record(
            category: .transfer,
            event: "diagnostics_download_completed",
            fields: [
                "mode": DeviceTransferSession.Mode.diagnostics.rawValue,
                "importedCount": String(imported),
            ]
        )
        return imported
    }

    private func decodeIndex(_ data: Data) throws -> DeviceDiagnosticsIndex {
        guard let index = try? JSONDecoder().decode(DeviceDiagnosticsIndex.self, from: data),
              index.schema == 1,
              index.source == "firmware",
              index.bootSequence > 0,
              index.chunks.count <= 128 else {
            throw DeviceDiagnosticsTransferError.invalidIndex
        }
        return index
    }

    private func request(
        session: DeviceTransferSession,
        path: String,
        method: String
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
        let (data, response) = try await urlSession.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode,
              200..<300 ~= status else {
            throw DeviceDiagnosticsTransferError.requestFailed(
                (response as? HTTPURLResponse)?.statusCode ?? -1
            )
        }
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidJSONL(_ data: Data) -> Bool {
        guard data.count <= 12 * 1024 * 1024 else { return false }
        var lines = data.split(
            separator: 0x0a,
            omittingEmptySubsequences: true
        )
        guard !lines.isEmpty else { return false }
        if data.last != 0x0a,
           let last = lines.last,
           (try? JSONSerialization.jsonObject(with: Data(last))) == nil {
            // A reset can leave only the final JSONL record incomplete. The
            // closed chunk is still useful; middle-line corruption remains a
            // hard failure below.
            lines.removeLast()
        }
        guard !lines.isEmpty else { return false }
        var previousSequence: UInt64?
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
                  sequenceValue >= 0 else {
                return false
            }
            if let fieldsValue = object["fields"] {
                guard let fields = fieldsValue as? [String: Any],
                      isPrivacySafe(fields) else { return false }
            }
            let sequence = UInt64(sequenceValue)
            if let previousSequence, sequence <= previousSequence {
                return false
            }
            previousSequence = sequence
        }
        return true
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
}
