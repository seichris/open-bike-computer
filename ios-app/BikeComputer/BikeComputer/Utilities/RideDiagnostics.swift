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
        "clockSynchronized",
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
        "runtimeBootSequence",
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
    var isDetailedTraceEnabled: Bool { get }
    func record(
        level: RideDiagnosticLevel,
        category: RideDiagnosticCategory,
        event: String,
        fields: [String: String],
        captureId: UUID?
    )
}

extension RideDiagnosticsEventSink {
    var isDetailedTraceEnabled: Bool { false }

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
    let retainedCaptureCount: Int
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
        guard entries.count <= Int(UInt16.max) else {
            throw RideDiagnosticsError.invalidArchiveEntry
        }
        let names = entries.map(\.0)
        if let duplicate = Dictionary(grouping: names, by: { $0 })
            .first(where: { $0.value.count > 1 })?.key {
            throw RideDiagnosticsError.unavailable(
                "The diagnostics bundle contains duplicate path \(duplicate)."
            )
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
            guard isSafePath(path) else {
                throw RideDiagnosticsError.unavailable(
                    "The diagnostics bundle contains unsafe path \(path)."
                )
            }
            guard data.count <= Int(UInt32.max),
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
    static let retainedCaptureLimit = 20
    static let retentionAge: TimeInterval = 14 * 24 * 60 * 60
    static let pendingRecordLimit = 256
    private static let deviceDigestSaltDefaultsKey =
        "rideDiagnostics.deviceDigestSalt.v1"

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
    private let privacyDigestKey = SymmetricKey(size: .bits256)
    private let deviceDigestKey: SymmetricKey
    private var sequence = 0
    private var chunkNumber = 1
    private var currentChunkURL: URL?
    private var currentChunkBytes = 0
    private var preDetailedContextURL: URL?
    private let standardCaptureId: UUID
    private var activeCaptureId: UUID?
    private var detailedTraceActive = false
    private var detailedTraceExpiry: Date?
    private var totalDropped = 0
    // Queue-confined storage state. The @Published value is a main-thread UI
    // snapshot and must never be mutated from the recorder queue.
    private var retainedBytesOnQueue = 0
    private struct PendingRecord {
        let level: RideDiagnosticLevel
        let category: RideDiagnosticCategory
        let event: String
        let fields: [String: String]
        let captureId: UUID?

        var isCritical: Bool { level == .warning || level == .error }
    }
    private let pendingLock = NSLock()
    private var pendingRecords: [PendingRecord] = []
    private var pendingDrainScheduled = false
    private var pendingAdmissionDrops = 0

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
        self.deviceDigestKey = Self.loadOrCreateDeviceDigestKey(
            userDefaults: userDefaults
        )
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

    var isDetailedTraceEnabled: Bool {
        queue.sync { detailedTraceActive }
    }

    var health: RideDiagnosticsRecorderHealth {
        queue.sync {
            healthOnQueue()
        }
    }

    func privacyDigest(_ data: Data) -> String {
        HMAC<SHA256>.authenticationCode(
            for: data,
            using: privacyDigestKey
        ).map { String(format: "%02x", $0) }.joined()
    }

    func deviceDigest(for stableIdentifier: String) -> String {
        String(HMAC<SHA256>.authenticationCode(
            for: Data(stableIdentifier.lowercased().utf8),
            using: deviceDigestKey
        ).map { String(format: "%02x", $0) }.joined().prefix(16))
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
        enqueue(PendingRecord(
            level: level,
            category: category,
            event: safeEvent,
            fields: safeFields,
            captureId: captureId
        ))
    }

    private func enqueue(_ pending: PendingRecord) {
        var scheduleDrain = false
        pendingLock.lock()
        if pendingRecords.count >= Self.pendingRecordLimit {
            if pending.isCritical,
               let expendable = pendingRecords.firstIndex(where: { !$0.isCritical }) {
                pendingRecords.remove(at: expendable)
                pendingAdmissionDrops += 1
            } else {
                pendingAdmissionDrops += 1
                pendingLock.unlock()
                return
            }
        }
        pendingRecords.append(pending)
        if !pendingDrainScheduled {
            pendingDrainScheduled = true
            scheduleDrain = true
        }
        pendingLock.unlock()
        if scheduleDrain {
            queue.async { [weak self] in self?.drainPendingRecords() }
        }
    }

    private func drainPendingRecords() {
        while true {
            let pending: PendingRecord
            let admissionDrops: Int
            pendingLock.lock()
            admissionDrops = pendingAdmissionDrops
            pendingAdmissionDrops = 0
            if pendingRecords.isEmpty {
                pendingDrainScheduled = false
                pendingLock.unlock()
                if admissionDrops > 0 {
                    totalDropped += admissionDrops
                    publishDropCount()
                }
                return
            }
            pending = pendingRecords.removeFirst()
            pendingLock.unlock()

            if admissionDrops > 0 {
                totalDropped += admissionDrops
                publishDropCount()
            }
            do {
                expireDetailedTraceIfNeeded()
                let event = RideDiagnosticEvent(
                    schema: Self.schema,
                    source: "ios",
                    sequence: sequence,
                    level: pending.level,
                    category: pending.category,
                    event: pending.event,
                    wallTime: isoFormatter.string(from: now()),
                    uptimeMs: max(
                        0,
                        Int((ProcessInfo.processInfo.systemUptime - startUptime) * 1000)
                    ),
                    processId: processId.uuidString.lowercased(),
                    captureId: (
                        pending.captureId ?? activeCaptureId ?? standardCaptureId
                    ).uuidString.lowercased(),
                    fields: pending.fields
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
    }

    func beginDetailedTrace() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.detailedTraceActive else { return }
            self.preDetailedContextURL = self.currentChunkURL
            self.rotateChunk()
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
            self.flushOnQueue()
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
            guard self.detailedTraceActive else { return }
            self.recordOnQueue(
                level: .info,
                category: .user,
                event: "detailed_trace_ended",
                fields: ["reason": Self.safeEnum(reason)]
            )
            self.rotateChunk()
            self.activeCaptureId = nil
            self.preDetailedContextURL = nil
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

    func hasImportedDeviceChunk(
        deviceDigest: String,
        bootSequence: UInt32,
        chunk: UInt32,
        sha256: String
    ) -> Bool {
        queue.sync {
            importedChunkURL(
                deviceDigest: deviceDigest,
                bootSequence: bootSequence,
                chunk: chunk,
                sha256: sha256
            )
                .map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    func importedDeviceChunkData(
        deviceDigest: String,
        bootSequence: UInt32,
        chunk: UInt32,
        sha256: String
    ) -> Data? {
        queue.sync {
            guard let url = importedChunkURL(
                deviceDigest: deviceDigest,
                bootSequence: bootSequence,
                chunk: chunk,
                sha256: sha256
            ) else { return nil }
            return try? Data(contentsOf: url)
        }
    }

    func importDeviceRecorderHealth(
        deviceDigest: String,
        bootSequence: UInt32,
        data: Data,
        enforceRetention: Bool = true
    ) throws {
        try queue.sync {
            guard Self.isValidDeviceDigest(deviceDigest),
                  bootSequence > 0, data.count <= 64 * 1024,
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw RideDiagnosticsError.unavailable(
                    "The device recorder-health snapshot is invalid."
                )
            }
            let directory = rootURL
                .appendingPathComponent("imported-device", isDirectory: true)
                .appendingPathComponent(deviceDigest, isDirectory: true)
                .appendingPathComponent(String(bootSequence), isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent("recorder-health.json")
            try data.write(to: url, options: .atomic)
            applyFileProtection(to: url)
            if enforceRetention {
                updateRetainedBytes()
                try pruneRetention()
            }
        }
    }

    @discardableResult
    func importDeviceChunk(
        deviceDigest: String,
        bootSequence: UInt32,
        chunk: UInt32,
        data: Data,
        sha256 expectedHash: String,
        enforceRetention: Bool = true
    ) throws -> URL {
        try queue.sync {
            guard Self.isValidDeviceDigest(deviceDigest),
                  bootSequence > 0, chunk > 0,
                  expectedHash.count == 64,
                  expectedHash.allSatisfy({ $0.isHexDigit }),
                  data.count <= Self.chunkLimit else {
                throw RideDiagnosticsError.unavailable("The device chunk metadata is invalid.")
            }
            let actualHash = sha256(data)
            guard actualHash == expectedHash.lowercased() else {
                throw RideDiagnosticsError.unavailable("The device chunk hash did not match its index.")
            }
            let directory = rootURL
                .appendingPathComponent("imported-device", isDirectory: true)
                .appendingPathComponent(deviceDigest, isDirectory: true)
                .appendingPathComponent(String(bootSequence), isDirectory: true)
            let normalizedHash = expectedHash.lowercased()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(
                String(format: "events-%06u-%@.jsonl", chunk, String(normalizedHash.prefix(16)))
            )
            // The caller has already validated the complete body and digest.
            // Always replace the destination atomically so a truncated or
            // otherwise corrupted cached file can recover on the next pull.
            try data.write(to: url, options: .atomic)
            applyFileProtection(to: url)
            if enforceRetention {
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
            }
            if enforceRetention {
                updateRetainedBytes()
                try pruneRetention()
            }
            return url
        }
    }

    func enforceRetention() throws {
        try queue.sync {
            updateRetainedBytes()
            try pruneRetention()
        }
    }

    func flush() {
        queue.sync {
            flushOnQueue()
        }
    }

    func exportBundle() throws -> URL {
        try queue.sync {
            flushOnQueue()
            let fileManager = FileManager.default
            let entries = try exportEntries()
            let outputURL = fileManager.temporaryDirectory
                .appendingPathComponent(exportFilename())
            try? fileManager.removeItem(at: outputURL)
            try RideDiagnosticsStoredZipWriter.write(entries: entries, to: outputURL)
            applyFileProtection(to: outputURL)
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
            preDetailedContextURL = nil
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
        if retainedBytesOnQueue + data.count > Self.retainedBytesLimit {
            try pruneRetention(reserving: data.count)
            guard retainedBytesOnQueue + data.count <= Self.retainedBytesLimit else {
                throw RideDiagnosticsError.unavailable(
                    "Diagnostic retention is full while the active capture is protected."
                )
            }
        }
        if currentChunkURL == nil || currentChunkBytes + data.count > Self.chunkLimit {
            rotateChunk()
        }
        guard let url = currentChunkURL else {
            throw RideDiagnosticsError.unavailable("Diagnostic storage is unavailable.")
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw RideDiagnosticsError.unavailable(
                    "Unable to create the diagnostic event chunk."
                )
            }
            applyFileProtection(to: url)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        currentChunkBytes += data.count
        retainedBytesOnQueue += data.count
        publishRetainedBytes(retainedBytesOnQueue)
        let shouldPrune = event.sequence == 0 ||
            retainedBytesOnQueue > Self.retainedBytesLimit
        if sequence % 16 == 0 {
            try writeManifest(enforceRetention: shouldPrune)
        } else if shouldPrune {
            try pruneRetention()
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
        if let currentChunkURL,
           FileManager.default.fileExists(atPath: currentChunkURL.path),
           let handle = try? FileHandle(forWritingTo: currentChunkURL) {
            try? handle.synchronize()
            try? handle.close()
        }
        try? writeManifest()
    }

    private func writeManifest(enforceRetention: Bool = true) throws {
        let manifest: [String: Any] = [
            "schema": Self.schema,
            "source": "ios",
            "processId": processId.uuidString.lowercased(),
            "createdAt": isoFormatter.string(from: now()),
            "chunkLimitBytes": Self.chunkLimit,
            "retentionBytes": Self.retainedBytesLimit,
            "retentionCaptureCount": Self.retainedCaptureLimit,
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
        updateRetainedBytes()
        if enforceRetention || retainedBytesOnQueue > Self.retainedBytesLimit {
            try pruneRetention()
        }
    }

    private func exportEntries() throws -> [(String, Data)] {
        let fileManager = FileManager.default
        var entries: [(String, Data)] = []
        let appRoot = rootURL.appendingPathComponent("app", isDirectory: true)
        if let files = fileManager.enumerator(at: appRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in files {
                guard file.pathExtension == "jsonl" || file.pathExtension == "json" else { continue }
                guard let relative = archiveRelativePath(file, under: appRoot) else {
                    throw RideDiagnosticsError.invalidArchiveEntry
                }
                entries.append(("app/" + relative, try Data(contentsOf: file)))
            }
        }
        let importedRoot = rootURL.appendingPathComponent("imported-device", isDirectory: true)
        if let files = fileManager.enumerator(at: importedRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in files {
                guard file.pathExtension == "jsonl" || file.pathExtension == "json" else { continue }
                guard let relative = archiveRelativePath(
                    file,
                    under: importedRoot
                ) else {
                    throw RideDiagnosticsError.invalidArchiveEntry
                }
                entries.append(("device/" + relative, try Data(contentsOf: file)))
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
            "retainedBytes": retainedBytesOnQueue,
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

    private func archiveRelativePath(_ file: URL, under root: URL) -> String? {
        let resolvedFile = file.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        guard resolvedFile.hasPrefix(prefix) else { return nil }
        let relative = String(resolvedFile.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
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

    private func allDiagnosticRetentionFiles() -> [URL] {
        let importedPrefix = rootURL
            .appendingPathComponent("imported-device", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let appPrefix = rootURL
            .appendingPathComponent("app", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard let files = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.compactMap { item -> URL? in
            guard let url = item as? URL else { return nil }
            let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            let isChunk = url.pathExtension == "jsonl"
            let isDeviceHealth = resolvedPath.hasPrefix(importedPrefix) &&
                url.lastPathComponent == "recorder-health.json"
            let isAppManifest = resolvedPath.hasPrefix(appPrefix) &&
                url.lastPathComponent == "manifest.json"
            guard isChunk || isDeviceHealth || isAppManifest else {
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

    private func allDiagnosticChunkFiles() -> [URL] {
        allDiagnosticRetentionFiles().filter { $0.pathExtension == "jsonl" }
    }

    private func allAppChunkFiles() -> [URL] {
        let prefix = rootURL
            .appendingPathComponent("app", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return allDiagnosticChunkFiles().filter {
            $0.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(prefix)
        }
    }

    private func importedChunkURL(
        deviceDigest: String,
        bootSequence: UInt32,
        chunk: UInt32,
        sha256: String
    ) -> URL? {
        guard Self.isValidDeviceDigest(deviceDigest),
              sha256.count == 64,
              sha256.allSatisfy({ $0.isHexDigit }) else { return nil }
        return rootURL
            .appendingPathComponent("imported-device", isDirectory: true)
            .appendingPathComponent(deviceDigest, isDirectory: true)
            .appendingPathComponent(String(bootSequence), isDirectory: true)
            .appendingPathComponent(
                String(format: "events-%06u-%@.jsonl", chunk, String(sha256.lowercased().prefix(16)))
            )
    }

    private func updateRetainedBytes() {
        retainedBytesOnQueue = allDiagnosticRetentionFiles().reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        publishRetainedBytes(retainedBytesOnQueue)
    }

    private func captureIDs(in url: URL) -> Set<String> {
        if url.lastPathComponent == "recorder-health.json" ||
            url.lastPathComponent == "manifest.json" {
            let siblingChunks = (try? FileManager.default.contentsOfDirectory(
                at: url.deletingLastPathComponent(),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ))?.filter { $0.pathExtension == "jsonl" } ?? []
            let siblingCaptures = siblingChunks.reduce(into: Set<String>()) {
                $0.formUnion(captureIDs(in: $1))
            }
            if !siblingCaptures.isEmpty { return siblingCaptures }
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        var captures: Set<String> = []
        for raw in data.split(separator: 0x0a, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(raw))
                    as? [String: Any],
                  let capture = object["captureId"] as? String,
                  !capture.isEmpty else { continue }
            captures.insert(capture)
        }
        let parentPath = url.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        if captures.isEmpty, !parentPath.isEmpty {
            let parentDigest = String(sha256(Data(parentPath.utf8)).prefix(16))
            captures.insert("uncorrelated:\(parentDigest)")
        }
        return captures
    }

    private func pruneRetention(reserving requiredBytes: Int = 0) throws {
        let fileManager = FileManager.default
        let cutoff = now().addingTimeInterval(-Self.retentionAge)
        var files = allDiagnosticRetentionFiles()
        let activeCaptures = Set([activeCaptureId?.uuidString.lowercased()].compactMap { $0 })
        let newestAppChunk = allAppChunkFiles().last
        let protectedPaths = Set(
            [currentChunkURL, preDetailedContextURL, newestAppChunk].compactMap {
                $0?.resolvingSymlinksInPath().standardizedFileURL.path
            }
        )
        func snapshot(_ files: [URL]) -> [URL: Set<String>] {
            Dictionary(uniqueKeysWithValues: files.map { ($0, captureIDs(in: $0)) })
        }
        func isProtected(_ url: URL, in capturesByFile: [URL: Set<String>]) -> Bool {
            protectedPaths.contains(
                url.resolvingSymlinksInPath().standardizedFileURL.path
            ) || !(capturesByFile[url] ?? []).isDisjoint(with: activeCaptures)
        }
        func protectedCaptures(
            in files: [URL],
            capturesByFile: [URL: Set<String>]
        ) -> Set<String> {
            files.reduce(into: activeCaptures) { captures, url in
                if isProtected(url, in: capturesByFile) {
                    captures.formUnion(capturesByFile[url] ?? [])
                }
            }
        }

        var capturesByFile = snapshot(files)
        for url in files where !isProtected(url, in: capturesByFile) {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now()
            if date < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }

        files = allDiagnosticRetentionFiles()
        capturesByFile = snapshot(files)
        let protectedCaptureIDs = protectedCaptures(
            in: files,
            capturesByFile: capturesByFile
        )
        var captureDates: [String: Date] = [:]
        for url in files {
            let date = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            for capture in capturesByFile[url] ?? [] {
                captureDates[capture] = max(captureDates[capture] ?? .distantPast, date)
            }
        }
        let retainedCaptures = captureDates.keys.sorted {
            (captureDates[$0] ?? .distantPast) < (captureDates[$1] ?? .distantPast)
        }
        let excess = max(0, retainedCaptures.count - Self.retainedCaptureLimit)
        let expiredCaptures = Set(
            retainedCaptures.lazy.filter { !protectedCaptureIDs.contains($0) }.prefix(excess)
        )
        if !expiredCaptures.isEmpty {
            for url in files where !isProtected(url, in: capturesByFile) {
                let captures = capturesByFile[url] ?? []
                if !captures.isDisjoint(with: expiredCaptures) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }

        updateRetainedBytes()
        files = allDiagnosticRetentionFiles()
        while retainedBytesOnQueue + requiredBytes > Self.retainedBytesLimit {
            capturesByFile = snapshot(files)
            let protectedCaptureIDs = protectedCaptures(
                in: files,
                capturesByFile: capturesByFile
            )
            var dates: [String: Date] = [:]
            for url in files {
                let date = (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                for capture in capturesByFile[url] ?? [] {
                    dates[capture] = max(dates[capture] ?? .distantPast, date)
                }
            }
            guard let oldestCapture = dates.keys
                .filter({ !protectedCaptureIDs.contains($0) })
                .min(by: { (dates[$0] ?? .distantPast) < (dates[$1] ?? .distantPast) }) else {
                break
            }
            let candidates = files.filter {
                !isProtected($0, in: capturesByFile) &&
                    (capturesByFile[$0] ?? []).contains(oldestCapture)
            }
            guard !candidates.isEmpty else { break }
            for candidate in candidates {
                try fileManager.removeItem(at: candidate)
            }
            files = allDiagnosticRetentionFiles()
            updateRetainedBytes()
        }
        updateRetainedBytes()
    }

    private func oldestEventDate() -> Date? {
        allDiagnosticRetentionFiles().compactMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }.min()
    }

    private func healthOnQueue() -> RideDiagnosticsRecorderHealth {
        let captureCount = Set(
            allDiagnosticRetentionFiles().flatMap { captureIDs(in: $0) }
        ).count
        return RideDiagnosticsRecorderHealth(
            schema: Self.schema,
            processId: processId.uuidString.lowercased(),
            retainedBytes: retainedBytesOnQueue,
            retainedChunkCount: allDiagnosticChunkFiles().count,
            retainedCaptureCount: captureCount,
            oldestWallTime: oldestEventDate().map(isoFormatter.string),
            newestWallTime: newestEventDate().map(isoFormatter.string),
            droppedEventCount: totalDropped,
            lastError: lastError,
            detailedTraceEnabled: detailedTraceActive,
            detailedTraceExpiresAt: detailedTraceExpiry.map(isoFormatter.string)
        )
    }

    private func newestEventDate() -> Date? {
        allDiagnosticRetentionFiles().compactMap { url in
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
        rotateChunk()
        activeCaptureId = nil
        preDetailedContextURL = nil
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

    private func publishRetainedBytes(_ bytes: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.retainedBytes = bytes
        }
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

    private static func isValidDeviceDigest(_ value: String) -> Bool {
        value.utf8.count == 16 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private static func loadOrCreateDeviceDigestKey(
        userDefaults: UserDefaults
    ) -> SymmetricKey {
        if let stored = userDefaults.data(forKey: deviceDigestSaltDefaultsKey),
           stored.count == 32 {
            return SymmetricKey(data: stored)
        }
        let key = SymmetricKey(size: .bits256)
        let encoded = key.withUnsafeBytes { Data($0) }
        userDefaults.set(encoded, forKey: deviceDigestSaltDefaultsKey)
        return key
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
