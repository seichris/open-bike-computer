//
//  RideDiagnostics.swift
//  BikeComputer
//
//  Local, privacy-bounded ride diagnostics. The recorder is deliberately
//  independent from BLE and navigation so it can continue through a radio
//  disconnect or a background transition.
//

import Combine
import CryptoKit
import Foundation

enum RideDiagnosticLevel: String, Codable, CaseIterable {
    case debug
    case info
    case warning
    case error
}

enum RideDiagnosticCategory: String, Codable, CaseIterable {
    case lifecycle
    case boot
    case ble
    case navigation
    case gps
    case workout
    case rideAutomation
    case storage
    case map
    case power
    case transfer
    case user
    case logger
}

/// Closed vocabulary shared by the recorder and device-chunk validator. A
/// field must be added here before a producer can persist it, keeping the
/// privacy contract reviewable at one call site.
enum RideDiagnosticsFieldPolicy {
    static let allowedKeys: Set<String> = [
        "accuracy", "accuracyAvailable", "accuracyBucket", "activeStage",
        "acknowledgedKind", "ageMs", "alertMode", "autoPauseEnabled",
        "authorization", "authorized", "available",
        "background", "bootSequence", "bytes", "chunk", "code",
        "completedStage", "consecutiveEarlyFailures", "diagnosticHold",
        "domain", "droppedCount", "durationLimit", "eventCount",
        "firstMissingUptimeMs", "firmwareBuild", "firmwareFingerprint",
        "firmwareTarget", "fixValid", "importedCount", "lastCriticalCategory",
        "lastCriticalEvent", "lastGapMs", "lastMissingUptimeMs",
        "storageErrorCount",
        "maximumGapMs", "messageBytes", "messageDigest", "kind", "mode",
        "networkTransport", "navigating",
        "profileVersion", "ready", "reason", "resetReason", "rideDetectionArmed",
        "rideGeneration", "routeLoaded", "rssiBucket", "sampleCount",
        "safeMode", "scope", "sequence", "sha256Prefix", "simulation",
        "sourceHealthMask", "speedAvailable", "state", "startMode", "storage",
        "connectionState", "pendingControl", "sessionPresent", "active",
        "transition", "result", "origin", "expectedState", "decisionSequence",
        "fallback",
        "viewingMap", "workoutActive",
    ]

    static func isAllowed(_ key: String) -> Bool {
        allowedKeys.contains(key)
    }
}

enum RideIssueCode: String, CaseIterable, Identifiable {
    case navigationWrong = "navigation_wrong"
    case deviceBlank = "device_blank"
    case connectionDrop = "connection_drop"
    case sensorMissing = "sensor_missing"
    case other = "other"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .navigationWrong: return "Navigation looked wrong"
        case .deviceBlank: return "Device screen went blank"
        case .connectionDrop: return "Connection dropped"
        case .sensorMissing: return "Sensor data disappeared"
        case .other: return "Other issue"
        }
    }
}

struct RideDiagnosticEvent: Codable, Equatable, Identifiable {
    let schema: Int
    let source: String
    let sequence: Int
    let level: RideDiagnosticLevel
    let category: RideDiagnosticCategory
    let event: String
    let wallTime: String?
    let uptimeMs: Int?
    let processId: String?
    let captureId: String?
    let fields: [String: String]

    var id: String { "\(source)-\(sequence)" }

    var renderedLine: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let line = String(data: data, encoding: .utf8) else {
            return "\(sequence) \(level.rawValue) \(category.rawValue).\(event)"
        }
        return line
    }
}

protocol RideDiagnosticsEventSink: AnyObject {
    func record(
        level: RideDiagnosticLevel,
        category: RideDiagnosticCategory,
        event: String,
        fields: [String: String],
        captureId: UUID?
    )
}

extension RideDiagnosticsEventSink {
    func record(
        category: RideDiagnosticCategory,
        event: String,
        fields: [String: String] = [:],
        captureId: UUID? = nil
    ) {
        record(
            level: .info,
            category: category,
            event: event,
            fields: fields,
            captureId: captureId
        )
    }
}

struct RideDiagnosticsRecorderHealth: Codable, Equatable {
    let schema: Int
    let processId: String
    let retainedBytes: Int
    let retainedChunkCount: Int
    let oldestWallTime: String?
    let newestWallTime: String?
    let droppedEventCount: Int
    let lastError: String?
    let detailedTraceEnabled: Bool
    let detailedTraceExpiresAt: String?
}

enum RideDiagnosticsError: LocalizedError, Equatable {
    case unavailable(String)
    case archiveTooLarge
    case invalidArchiveEntry

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .archiveTooLarge: return "The diagnostics bundle is too large."
        case .invalidArchiveEntry: return "The diagnostics bundle contains an invalid path."
        }
    }
}

/// A small stored-ZIP writer. Diagnostics are already bounded and compressing
/// them would make exports nondeterministic and require another dependency.
enum RideDiagnosticsStoredZipWriter {
    private struct CentralEntry {
        let name: Data
        let size: UInt32
        let crc: UInt32
        let offset: UInt32
    }

    static func write(entries: [(String, Data)], to url: URL) throws {
        guard entries.count <= Int(UInt16.max),
              Set(entries.map(\.0)).count == entries.count else {
            throw RideDiagnosticsError.invalidArchiveEntry
        }
        let output = FileManager.default
        guard output.createFile(atPath: url.path, contents: nil) else {
            throw RideDiagnosticsError.unavailable("Unable to create diagnostics export.")
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var central: [CentralEntry] = []
        for (path, data) in entries {
            guard isSafePath(path),
                  data.count <= Int(UInt32.max),
                  offset <= UInt64(UInt32.max) else {
                throw RideDiagnosticsError.invalidArchiveEntry
            }
            let name = Data(path.utf8)
            guard !name.isEmpty, name.count <= Int(UInt16.max) else {
                throw RideDiagnosticsError.invalidArchiveEntry
            }
            let crc = crc32(data)
            let localOffset = UInt32(offset)
            var header = Data()
            appendUInt32LE(0x0403_4B50, to: &header)
            appendUInt16LE(20, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt32LE(crc, to: &header)
            appendUInt32LE(UInt32(data.count), to: &header)
            appendUInt32LE(UInt32(data.count), to: &header)
            appendUInt16LE(UInt16(name.count), to: &header)
            appendUInt16LE(0, to: &header)
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: name)
            try handle.write(contentsOf: data)
            offset += UInt64(header.count + name.count + data.count)
            central.append(CentralEntry(
                name: name,
                size: UInt32(data.count),
                crc: crc,
                offset: localOffset
            ))
        }

        guard offset <= UInt64(UInt32.max) else {
            throw RideDiagnosticsError.archiveTooLarge
        }
        let directoryOffset = UInt32(offset)
        for entry in central {
            var header = Data()
            appendUInt32LE(0x0201_4B50, to: &header)
            appendUInt16LE(20, to: &header)
            appendUInt16LE(20, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt32LE(entry.crc, to: &header)
            appendUInt32LE(entry.size, to: &header)
            appendUInt32LE(entry.size, to: &header)
            appendUInt16LE(UInt16(entry.name.count), to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt16LE(0, to: &header)
            appendUInt32LE(0, to: &header)
            appendUInt32LE(entry.offset, to: &header)
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: entry.name)
            offset += UInt64(header.count + entry.name.count)
        }

        guard offset <= UInt64(UInt32.max) else {
            throw RideDiagnosticsError.archiveTooLarge
        }
        var footer = Data()
        appendUInt32LE(0x0605_4B50, to: &footer)
        appendUInt16LE(0, to: &footer)
        appendUInt16LE(0, to: &footer)
        appendUInt16LE(UInt16(central.count), to: &footer)
        appendUInt16LE(UInt16(central.count), to: &footer)
        appendUInt32LE(UInt32(offset) - directoryOffset, to: &footer)
        appendUInt32LE(directoryOffset, to: &footer)
        appendUInt16LE(0, to: &footer)
        try handle.write(contentsOf: footer)
    }

    private static func isSafePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        return !path.isEmpty && !path.contains("\\") && !path.hasPrefix("/") &&
            components.allSatisfy { $0 != "." && $0 != ".." && !$0.isEmpty }
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        appendUInt16LE(UInt16(value & 0xffff), to: &data)
        appendUInt16LE(UInt16((value >> 16) & 0xffff), to: &data)
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1
                    ? (crc >> 1) ^ 0xedb8_8320
                    : crc >> 1
            }
        }
        return crc ^ 0xffff_ffff
    }
}

final class RideDiagnosticsRecorder: ObservableObject, RideDiagnosticsEventSink {
    static let schema = 1
    static let chunkLimit = 256 * 1024
    static let retainedBytesLimit = 50 * 1024 * 1024
    static let retainedChunkLimit = 20
    static let retentionAge: TimeInterval = 14 * 24 * 60 * 60

    @Published private(set) var recentEvents: [RideDiagnosticEvent] = []
    @Published private(set) var retainedBytes: Int = 0
    @Published private(set) var droppedEventCount: Int = 0
    @Published private(set) var lastError: String?
    @Published private(set) var detailedTraceEnabled = false
    @Published private(set) var detailedTraceExpiresAt: Date?

    let processId: UUID
    let rootURL: URL

    private let queue: DispatchQueue
    private let now: () -> Date
    private let startUptime: TimeInterval
    private let isoFormatter: ISO8601DateFormatter
    private let userDefaults: UserDefaults
    private var sequence = 0
    private var chunkNumber = 1
    private var currentChunkURL: URL?
    private var currentChunkBytes = 0
    private let standardCaptureId: UUID
    private var activeCaptureId: UUID?
    private var detailedTraceActive = false
    private var detailedTraceExpiry: Date?
    private var totalDropped = 0

    init(
        rootURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        userDefaults: UserDefaults = .standard
    ) {
        self.processId = UUID()
        self.standardCaptureId = UUID()
        self.now = now
        self.startUptime = ProcessInfo.processInfo.systemUptime
        self.queue = DispatchQueue(
            label: "com.bicino.ride-diagnostics",
            qos: .utility
        )
        self.userDefaults = userDefaults
        self.isoFormatter = ISO8601DateFormatter()
        self.isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.rootURL = support
                .appendingPathComponent("BicinoDiagnostics", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        }

        queue.sync {
            do {
                try prepareStorage()
            } catch {
                publishError(error.localizedDescription)
            }
        }
        record(
            category: .lifecycle,
            event: "recorder_started",
            fields: ["storage": "application_support"]
        )
    }

    var currentCaptureID: UUID? {
        queue.sync { activeCaptureId ?? standardCaptureId }
    }

    var currentCaptureIDString: String? {
        currentCaptureID?.uuidString.lowercased()
    }

    var health: RideDiagnosticsRecorderHealth {
        queue.sync {
            healthOnQueue()
        }
    }

    func record(
        level: RideDiagnosticLevel = .info,
        category: RideDiagnosticCategory,
        event: String,
        fields: [String: String] = [:],
        captureId: UUID? = nil
    ) {
        let safeEvent = Self.safeEventName(event)
        let safeFields = Self.sanitize(fields: fields)
        guard !safeEvent.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            do {
                self.expireDetailedTraceIfNeeded()
                let event = RideDiagnosticEvent(
                    schema: Self.schema,
                    source: "ios",
                    sequence: self.sequence,
                    level: level,
                    category: category,
                    event: safeEvent,
                    wallTime: self.isoFormatter.string(from: self.now()),
                    uptimeMs: max(0, Int((ProcessInfo.processInfo.systemUptime - self.startUptime) * 1000)),
                    processId: self.processId.uuidString.lowercased(),
                    captureId: (captureId ?? self.activeCaptureId ?? self.standardCaptureId).uuidString.lowercased(),
                    fields: safeFields
                )
                self.sequence += 1
                try self.append(event)
                self.publish(event)
            } catch {
                self.totalDropped += 1
                self.publishDropCount()
                self.publishError(error.localizedDescription)
            }
        }
    }

    func beginDetailedTrace() {
        queue.async { [weak self] in
            guard let self else { return }
            self.activeCaptureId = UUID()
            let expiry = self.now().addingTimeInterval(4 * 60 * 60)
            self.detailedTraceExpiry = expiry
            self.detailedTraceActive = true
            self.publishDetailedState()
            self.recordOnQueue(
                level: .info,
                category: .user,
                event: "detailed_trace_started",
                fields: ["durationLimit": "4h"]
            )
            self.queue.asyncAfter(deadline: .now() + 4 * 60 * 60) { [weak self] in
                guard let self,
                      self.detailedTraceActive,
                      self.detailedTraceExpiry == expiry else { return }
                self.expireDetailedTraceIfNeeded(force: true)
                self.flushOnQueue()
            }
        }
    }

    func endDetailedTrace(reason: String = "user") {
        queue.async { [weak self] in
            guard let self else { return }
            self.recordOnQueue(
                level: .info,
                category: .user,
                event: "detailed_trace_ended",
                fields: ["reason": Self.safeEnum(reason)]
            )
            self.activeCaptureId = nil
            self.detailedTraceExpiry = nil
            self.detailedTraceActive = false
            self.publishDetailedState()
            self.flushOnQueue()
        }
    }

    func markIssue(_ code: RideIssueCode) {
        record(
            category: .user,
            event: "issue_marker",
            fields: ["code": code.rawValue],
            captureId: currentCaptureID
        )
    }

    func recordApplicationLifecycle(_ event: String, state: String) {
        record(
            category: .lifecycle,
            event: event,
            fields: ["state": Self.safeEnum(state)],
            captureId: currentCaptureID
        )
    }

    func hasImportedDeviceChunk(bootSequence: UInt32, chunk: UInt32, sha256: String) -> Bool {
        queue.sync {
            importedChunkURL(bootSequence: bootSequence, chunk: chunk, sha256: sha256)
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    @discardableResult
    func importDeviceChunk(
        bootSequence: UInt32,
        chunk: UInt32,
        data: Data,
        sha256 expectedHash: String
    ) throws -> URL {
        try queue.sync {
            guard bootSequence > 0, chunk > 0,
                  expectedHash.count == 64,
                  expectedHash.allSatisfy({ $0.isHexDigit }),
                  data.count <= 12 * 1024 * 1024 else {
                throw RideDiagnosticsError.unavailable("The device chunk metadata is invalid.")
            }
            let actualHash = sha256(data)
            guard actualHash == expectedHash.lowercased() else {
                throw RideDiagnosticsError.unavailable("The device chunk hash did not match its index.")
            }
            let directory = rootURL
                .appendingPathComponent("imported-device", isDirectory: true)
                .appendingPathComponent(String(bootSequence), isDirectory: true)
            let normalizedHash = expectedHash.lowercased()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(
                String(format: "events-%06u-%@.jsonl", chunk, String(normalizedHash.prefix(16)))
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
                applyFileProtection(to: url)
            }
            recordOnQueue(
                category: .transfer,
                event: "device_chunk_imported",
                fields: [
                    "bootSequence": String(bootSequence),
                    "chunk": String(chunk),
                    "bytes": String(data.count),
                    "sha256Prefix": String(expectedHash.prefix(16)),
                ]
            )
            return url
        }
    }

    func exportBundle() throws -> URL {
        try queue.sync {
            flushOnQueue()
            let fileManager = FileManager.default
            let exportRoot = fileManager.temporaryDirectory
                .appendingPathComponent("Bicino-Diagnostics-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: exportRoot, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: exportRoot) }

            let entries = try exportEntries()
            let outputURL = fileManager.temporaryDirectory
                .appendingPathComponent(exportFilename())
            try? fileManager.removeItem(at: outputURL)
            try RideDiagnosticsStoredZipWriter.write(entries: entries, to: outputURL)
            return outputURL
        }
    }

    func deleteLocalLogs() throws {
        try queue.sync {
            try FileManager.default.removeItem(at: rootURL)
            try prepareStorage()
            sequence = 0
            chunkNumber = 1
            currentChunkURL = nil
            currentChunkBytes = 0
            totalDropped = 0
            publishDropCount()
            recordOnQueue(
                category: .lifecycle,
                event: "logs_deleted",
                fields: ["scope": "iphone"]
            )
        }
    }

    /// Returns a bounded view suitable for Developer Settings without making
    /// the durable recorder depend on the legacy debug-events array.
    func recentDebugLines(limit: Int = 40) -> [String] {
        Array(recentEvents.suffix(max(0, limit))).map { event in
            let timestamp = event.wallTime ?? "-"
            return "\(timestamp) \(event.category.rawValue).\(event.event)"
        }
    }

    private func prepareStorage() throws {
        let appDirectory = rootURL
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent(processId.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("imported-device", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent("exports", isDirectory: true),
            withIntermediateDirectories: true
        )
        applyFileProtection(to: rootURL)

        let chunks = chunkFiles()
        if let latest = chunks.last {
            currentChunkURL = latest
            currentChunkBytes = (try? Data(contentsOf: latest).count) ?? 0
            chunkNumber = (Int(latest.deletingPathExtension().lastPathComponent.split(separator: "-").last ?? "0") ?? 0) + 1
        } else {
            currentChunkURL = appDirectory.appendingPathComponent("events-000001.jsonl")
            currentChunkBytes = 0
            chunkNumber = 2
        }
        updateRetainedBytes()
        try pruneRetention()
    }

    private func append(_ event: RideDiagnosticEvent) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(event)
        data.append(0x0a)
        guard data.count <= 8 * 1024 else {
            throw RideDiagnosticsError.unavailable("Diagnostic event exceeded the record limit.")
        }
        if currentChunkURL == nil || currentChunkBytes + data.count > Self.chunkLimit {
            rotateChunk()
        }
        guard let url = currentChunkURL else {
            throw RideDiagnosticsError.unavailable("Diagnostic storage is unavailable.")
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        currentChunkBytes += data.count
        updateRetainedBytes()
        try pruneRetention()
        if sequence % 16 == 0 {
            try writeManifest()
        }
    }

    private func recordOnQueue(
        level: RideDiagnosticLevel = .info,
        category: RideDiagnosticCategory,
        event: String,
        fields: [String: String]
    ) {
        do {
            let event = RideDiagnosticEvent(
                schema: Self.schema,
                source: "ios",
                sequence: sequence,
                level: level,
                category: category,
                event: Self.safeEventName(event),
                wallTime: isoFormatter.string(from: now()),
                uptimeMs: max(0, Int((ProcessInfo.processInfo.systemUptime - startUptime) * 1000)),
                processId: processId.uuidString.lowercased(),
                captureId: (activeCaptureId ?? standardCaptureId).uuidString.lowercased(),
                fields: Self.sanitize(fields: fields)
            )
            sequence += 1
            try append(event)
            publish(event)
        } catch {
            totalDropped += 1
            publishDropCount()
            publishError(error.localizedDescription)
        }
    }

    private func rotateChunk() {
        let appDirectory = rootURL
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent(processId.uuidString.lowercased(), isDirectory: true)
        currentChunkURL = appDirectory.appendingPathComponent(
            String(format: "events-%06d.jsonl", chunkNumber)
        )
        chunkNumber += 1
        currentChunkBytes = 0
        publishEventless(category: .storage, event: "chunk_rotated", fields: ["chunk": String(chunkNumber - 1)])
    }

    private func flushOnQueue() {
        try? writeManifest()
    }

    private func writeManifest() throws {
        let manifest: [String: Any] = [
            "schema": Self.schema,
            "source": "ios",
            "processId": processId.uuidString.lowercased(),
            "createdAt": isoFormatter.string(from: now()),
            "chunkLimitBytes": Self.chunkLimit,
            "retentionBytes": Self.retainedBytesLimit,
            "retentionChunkCount": Self.retainedChunkLimit,
            "retentionAgeDays": 14,
            "droppedEventCount": totalDropped,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let url = rootURL
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent(processId.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("manifest.json")
        try data.write(to: url, options: .atomic)
        applyFileProtection(to: url)
    }

    private func exportEntries() throws -> [(String, Data)] {
        let fileManager = FileManager.default
        var entries: [(String, Data)] = []
        let appRoot = rootURL.appendingPathComponent("app", isDirectory: true)
        if let files = fileManager.enumerator(at: appRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in files {
                guard file.pathExtension == "jsonl" || file.lastPathComponent == "manifest.json" else { continue }
                let relative = file.path.replacingOccurrences(of: appRoot.path + "/", with: "app/")
                entries.append((relative, try Data(contentsOf: file)))
            }
        }
        let importedRoot = rootURL.appendingPathComponent("imported-device", isDirectory: true)
        if let files = fileManager.enumerator(at: importedRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in files {
                guard file.pathExtension == "jsonl" || file.lastPathComponent == "manifest.json" else { continue }
                let relative = file.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                entries.append(("device/" + relative.replacingOccurrences(of: "imported-device/", with: ""), try Data(contentsOf: file)))
            }
        }

        let health = healthOnQueue()
        let healthData = try JSONEncoder.diagnosticsEncoder.encode(health)
        entries.append(("summary/recorder-health.json", healthData))
        let manifest: [String: Any] = [
            "schema": Self.schema,
            "exportedAt": isoFormatter.string(from: now()),
            "appProcessId": processId.uuidString.lowercased(),
            "sourceStreams": entries.map(\.0).filter { $0.hasSuffix(".jsonl") },
            "captureId": (activeCaptureId ?? standardCaptureId).uuidString.lowercased(),
            "retainedBytes": retainedBytes,
            "droppedEventCount": totalDropped,
            "privacy": "coordinates_addresses_credentials_health_values_and_raw_sensors_excluded",
        ]
        entries.append(("manifest.json", try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])))
        let checksums = entries
            .sorted { $0.0 < $1.0 }
            .map { "\(sha256($0.1))  \($0.0)" }
            .joined(separator: "\n") + "\n"
        entries.append(("checksums.sha256", Data(checksums.utf8)))
        return entries.sorted { $0.0 < $1.0 }
    }

    private func exportFilename() -> String {
        let stamp = isoFormatter.string(from: now())
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
        let shortID = String(processId.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        return "Bicino-Diagnostics-\(stamp)-\(shortID).zip"
    }

    private func chunkFiles() -> [URL] {
        let appDirectory = rootURL
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent(processId.uuidString.lowercased(), isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(
            at: appDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
    }

    private func allAppChunkFiles() -> [URL] {
        let appRoot = rootURL.appendingPathComponent("app", isDirectory: true)
        guard let files = FileManager.default.enumerator(
            at: appRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "jsonl" else {
                return nil
            }
            return url
        }.sorted {
            let leftDate = (try? $0.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            let rightDate = (try? $1.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            return $0.path < $1.path
        }
    }

    private func importedChunkURL(
        bootSequence: UInt32,
        chunk: UInt32,
        sha256: String
    ) -> URL? {
        guard sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit }) else { return nil }
        return rootURL
            .appendingPathComponent("imported-device", isDirectory: true)
            .appendingPathComponent(String(bootSequence), isDirectory: true)
            .appendingPathComponent(
                String(format: "events-%06u-%@.jsonl", chunk, String(sha256.lowercased().prefix(16)))
            )
    }

    private func updateRetainedBytes() {
        retainedBytes = allAppChunkFiles().reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private func pruneRetention() throws {
        let fileManager = FileManager.default
        let cutoff = now().addingTimeInterval(-Self.retentionAge)
        var chunks = allAppChunkFiles()
        for url in chunks where url != currentChunkURL {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now()
            if date < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
        chunks = allAppChunkFiles()
        while chunks.count > Self.retainedChunkLimit || retainedBytes > Self.retainedBytesLimit {
            guard let candidate = chunks.first(where: { $0 != currentChunkURL }) else { break }
            try fileManager.removeItem(at: candidate)
            chunks.removeFirst()
            updateRetainedBytes()
        }
        updateRetainedBytes()
    }

    private func oldestEventDate() -> Date? {
        allAppChunkFiles().compactMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }.min()
    }

    private func healthOnQueue() -> RideDiagnosticsRecorderHealth {
        RideDiagnosticsRecorderHealth(
            schema: Self.schema,
            processId: processId.uuidString.lowercased(),
            retainedBytes: retainedBytes,
            retainedChunkCount: allAppChunkFiles().count,
            oldestWallTime: oldestEventDate().map(isoFormatter.string),
            newestWallTime: newestEventDate().map(isoFormatter.string),
            droppedEventCount: totalDropped,
            lastError: lastError,
            detailedTraceEnabled: detailedTraceActive,
            detailedTraceExpiresAt: detailedTraceExpiry.map(isoFormatter.string)
        )
    }

    private func newestEventDate() -> Date? {
        allAppChunkFiles().compactMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }.max()
    }

    private func expireDetailedTraceIfNeeded(force: Bool = false) {
        guard detailedTraceActive,
              let expires = detailedTraceExpiry,
              (force || now() >= expires) else { return }
        recordOnQueue(
            category: .user,
            event: "detailed_trace_ended",
            fields: ["reason": "time_limit"]
        )
        activeCaptureId = nil
        detailedTraceExpiry = nil
        detailedTraceActive = false
        publishDetailedState()
    }

    private func publish(_ event: RideDiagnosticEvent) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentEvents.append(event)
            if self.recentEvents.count > 100 {
                self.recentEvents.removeFirst(self.recentEvents.count - 100)
            }
        }
    }

    private func publishEventless(
        category: RideDiagnosticCategory,
        event: String,
        fields: [String: String]
    ) {
        // Rotation is an implementation detail; do not recursively append to
        // the file being rotated. The next normal event records the outcome.
        DispatchQueue.main.async { [weak self] in
            self?.lastError = nil
        }
        _ = (category, event, fields)
    }

    private func publishDropCount() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.droppedEventCount = self.totalDropped
        }
    }

    private func publishDetailedState() {
        let enabled = detailedTraceActive
        let expiry = detailedTraceExpiry
        DispatchQueue.main.async { [weak self] in
            self?.detailedTraceEnabled = enabled
            self?.detailedTraceExpiresAt = expiry
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = String(message.prefix(160))
        }
    }

    private func applyFileProtection(to url: URL) {
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? protectedURL.setResourceValues(values)
    }

    private static func safeEventName(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
        }
        return String(String.UnicodeScalarView(allowed).prefix(64))
    }

    private static func safeEnum(_ value: String) -> String {
        safeEventName(value).lowercased()
    }

    private static func sanitize(fields: [String: String]) -> [String: String] {
        let forbidden = [
            "latitude", "longitude", "coordinate", "address", "instruction",
            "destination", "password", "credential", "token", "ownerkey",
            "healthkit", "heartrate", "heart_rate", "rawimu", "raw_imu", "payload",
        ]
        var result: [String: String] = [:]
        for (key, value) in fields.prefix(32) {
            let normalizedKey = key.replacingOccurrences(of: "-", with: "_").lowercased()
            let normalizedValue = value.lowercased()
            guard RideDiagnosticsFieldPolicy.isAllowed(key),
                  !forbidden.contains(where: { normalizedKey.contains($0) }),
                  !normalizedValue.contains("bearer "),
                  !normalizedValue.contains("x-bikecomputer-transfer-token"),
                  !value.contains("\n"),
                  value.utf8.count <= 256 else { continue }
            result[String(key.prefix(64))] = String(value.prefix(256))
        }
        return result
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var diagnosticsEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
