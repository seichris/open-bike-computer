//
//  RideDiagnostics.swift
//  BikeComputer
//
//  Local, privacy-bounded ride diagnostics. The recorder is deliberately
//  independent from BLE and navigation so it can continue through a radio
//  disconnect or a background transition.
//

import Combine
import CoreFoundation
import CryptoKit
import Foundation

nonisolated enum RideDiagnosticLevel: String, Codable, CaseIterable {
    case debug
    case info
    case warning
    case error
}

nonisolated enum RideDiagnosticCategory: String, Codable, CaseIterable {
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

enum RideDiagnosticsRideLifecyclePolicy {
    static func isRideActive(
        navigating: Bool,
        workoutActive: Bool
    ) -> Bool {
        navigating || workoutActive
    }

    static func didEndRide(previous: Bool, current: Bool) -> Bool {
        previous && !current
    }
}

/// Closed vocabulary shared by the recorder and device-chunk validator. A
/// field must be added here before a producer can persist it, keeping the
/// privacy contract reviewable at one call site.
nonisolated enum RideDiagnosticsFieldPolicy {
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
        "lastFailureStage", "lastFailureCompletedStage",
        "lastFailureResetReason",
        "mapDetail", "mapPhase", "mapProgressMs",
        "storageErrorCount",
        "maximumGapMs", "messageBytes", "messageDigest", "kind", "mode",
        "networkTransport", "navigating",
        "profileVersion", "ready", "reason", "resetReason", "rideDetectionArmed",
        "rideGeneration", "routeLoaded", "rssiBucket", "sampleCount",
        "runtimeBootSequence",
        "safeMode", "scope", "sequence", "sha256Prefix", "simulation",
        "sourceHealthMask", "speedAvailable", "state", "startMode", "storage",
        "connectionState", "pendingControl", "sessionPresent", "active",
        "transition", "uiPhase", "uiProgressMs", "result", "origin",
        "expectedState", "decisionSequence",
        "fallback",
        "viewingMap", "watchdogCoreMask", "watchdogUptimeMs", "workoutActive",
        "writerDetail", "writerPhase", "writerProgressMs",
    ]
    static let firmwareNumberKeys: Set<String> = [
        "accuracy", "activeStage", "ageMs", "alertMode", "bootSequence",
        "bytes", "chunk", "completedStage", "consecutiveEarlyFailures",
        "decisionSequence", "droppedCount", "eventCount", "firmwareBuild",
        "firstMissingUptimeMs", "importedCount", "lastGapMs",
        "lastFailureStage", "lastFailureCompletedStage",
        "lastFailureResetReason", "lastMissingUptimeMs", "mapDetail",
        "mapProgressMs", "maximumGapMs",
        "messageBytes", "profileVersion", "resetReason", "rideGeneration",
        "runtimeBootSequence", "sampleCount", "sequence", "sourceHealthMask",
        "storageErrorCount", "uiProgressMs", "watchdogCoreMask",
        "watchdogUptimeMs", "writerDetail", "writerProgressMs",
    ]
    static let firmwareBooleanKeys: Set<String> = [
        "accuracyAvailable", "active", "autoPauseEnabled", "authorized",
        "available", "background", "clockSynchronized", "diagnosticHold",
        "fallback", "fixValid", "navigating", "pendingControl", "ready",
        "rideDetectionArmed", "routeLoaded", "safeMode", "sessionPresent",
        "simulation", "speedAvailable", "viewingMap", "workoutActive",
    ]

    static func isAllowed(_ key: String) -> Bool {
        allowedKeys.contains(key)
    }

    static func isJSONBoolean(_ value: Any?) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func isFirmwareFieldTypeValid(key: String, value: Any) -> Bool {
        if firmwareNumberKeys.contains(key) {
            return value is NSNumber && !isJSONBoolean(value)
        }
        if firmwareBooleanKeys.contains(key) {
            return isJSONBoolean(value)
        }
        return value is String
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

    private enum CodingKeys: String, CodingKey {
        case schema
        case processId
        case retainedBytes
        case retainedChunkCount
        case retainedCaptureCount
        case oldestWallTime
        case newestWallTime
        case droppedEventCount
        case lastError
        case detailedTraceEnabled
        case detailedTraceExpiresAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(processId, forKey: .processId)
        try container.encode(retainedBytes, forKey: .retainedBytes)
        try container.encode(retainedChunkCount, forKey: .retainedChunkCount)
        try container.encode(retainedCaptureCount, forKey: .retainedCaptureCount)
        try container.encode(oldestWallTime, forKey: .oldestWallTime)
        try container.encode(newestWallTime, forKey: .newestWallTime)
        try container.encode(droppedEventCount, forKey: .droppedEventCount)
        try container.encode(lastError, forKey: .lastError)
        try container.encode(detailedTraceEnabled, forKey: .detailedTraceEnabled)
        try container.encode(detailedTraceExpiresAt, forKey: .detailedTraceExpiresAt)
    }
}

nonisolated enum RideDiagnosticsError: LocalizedError, Equatable {
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
nonisolated enum RideDiagnosticsStoredZipWriter {
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
        var handleClosed = false
        defer {
            if !handleClosed {
                try? handle.close()
            }
        }

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
        try handle.synchronize()
        try handle.close()
        handleClosed = true
        try validateStoredArchive(entries: entries, at: url)
    }

    private static func validateStoredArchive(
        entries: [(String, Data)],
        at url: URL
    ) throws {
        let archive = try Data(contentsOf: url, options: [.mappedIfSafe])
        var cursor = 0
        var localOffsets: [UInt32] = []

        func uint16(at offset: Int) -> UInt16? {
            guard offset >= 0, offset + 2 <= archive.count else { return nil }
            return UInt16(archive[offset]) |
                (UInt16(archive[offset + 1]) << 8)
        }
        func uint32(at offset: Int) -> UInt32? {
            guard let low = uint16(at: offset),
                  let high = uint16(at: offset + 2) else { return nil }
            return UInt32(low) | (UInt32(high) << 16)
        }
        func failValidation() throws -> Never {
            throw RideDiagnosticsError.unavailable(
                "The diagnostics export failed its ZIP integrity check."
            )
        }

        for (path, payload) in entries {
            guard uint32(at: cursor) == 0x0403_4B50,
                  uint16(at: cursor + 8) == 0,
                  uint32(at: cursor + 14) == crc32(payload),
                  uint32(at: cursor + 18) == UInt32(payload.count),
                  uint32(at: cursor + 22) == UInt32(payload.count),
                  let nameLength = uint16(at: cursor + 26),
                  let extraLength = uint16(at: cursor + 28) else {
                try failValidation()
            }
            let localOffset = cursor
            let nameStart = cursor + 30
            let payloadStart = nameStart + Int(nameLength) + Int(extraLength)
            let payloadEnd = payloadStart + payload.count
            guard payloadEnd <= archive.count,
                  Data(archive[nameStart..<(nameStart + Int(nameLength))]) ==
                    Data(path.utf8),
                  Data(archive[payloadStart..<payloadEnd]) == payload else {
                try failValidation()
            }
            localOffsets.append(UInt32(localOffset))
            cursor = payloadEnd
        }

        let centralOffset = cursor
        for (index, (path, payload)) in entries.enumerated() {
            guard uint32(at: cursor) == 0x0201_4B50,
                  uint16(at: cursor + 10) == 0,
                  uint32(at: cursor + 16) == crc32(payload),
                  uint32(at: cursor + 20) == UInt32(payload.count),
                  uint32(at: cursor + 24) == UInt32(payload.count),
                  let nameLength = uint16(at: cursor + 28),
                  let extraLength = uint16(at: cursor + 30),
                  let commentLength = uint16(at: cursor + 32),
                  uint32(at: cursor + 42) == localOffsets[index] else {
                try failValidation()
            }
            let nameStart = cursor + 46
            let next = nameStart + Int(nameLength) + Int(extraLength) +
                Int(commentLength)
            guard next <= archive.count,
                  Data(archive[nameStart..<(nameStart + Int(nameLength))]) ==
                    Data(path.utf8) else {
                try failValidation()
            }
            cursor = next
        }

        guard uint32(at: cursor) == 0x0605_4B50,
              uint16(at: cursor + 8) == UInt16(entries.count),
              uint16(at: cursor + 10) == UInt16(entries.count),
              uint32(at: cursor + 12) == UInt32(cursor - centralOffset),
              uint32(at: cursor + 16) == UInt32(centralOffset),
              uint16(at: cursor + 20) == 0,
              cursor + 22 == archive.count else {
            try failValidation()
        }
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

struct RideDiagnosticsCaptureBinding: Equatable {
    let captureID: UUID
    let detailed: Bool
}

final class RideDiagnosticsRecorder:
    ObservableObject,
    RideDiagnosticsEventSink,
    @unchecked Sendable
{
    nonisolated static let schema = 1
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
    @Published private(set) var captureBinding: RideDiagnosticsCaptureBinding
    @Published private(set) var lastDeviceImportAt: Date?
    @Published private(set) var oldestRetainedAt: Date?
    @Published private(set) var newestRetainedAt: Date?

    let processId: UUID
    let rootURL: URL

    private let queue: DispatchQueue
    private let now: () -> Date
    private let startUptime: TimeInterval
    private let isoFormatter: ISO8601DateFormatter
    private let userDefaults: UserDefaults
    private let privacyDigestKey = SymmetricKey(size: .bits256)
    private let deviceDigestKey: SymmetricKey
    private let captureSnapshotLock = NSLock()
    private var captureBindingSnapshot: RideDiagnosticsCaptureBinding
    private var sequence = 0
    private var chunkNumber = 1
    private var currentChunkURL: URL?
    private var currentChunkBytes = 0
    private var preDetailedContextURL: URL?
    private var standardCaptureId: UUID
    private var standardCaptureStartedAt: Date
    private var activeCaptureId: UUID?
    private var detailedTraceActive = false
    private var detailedTraceExpiry: Date?
    private var totalDropped = 0
    private var lastErrorOnQueue: String?
    private var lastDeviceImportAtOnQueue: Date?
    // Queue-confined storage state. The @Published value is a main-thread UI
    // snapshot and must never be mutated from the recorder queue.
    private var retainedBytesOnQueue = 0
    private struct CaptureIDCacheEntry {
        let bytes: Int
        let modifiedAt: Date?
        let captures: Set<String>
    }
    private var captureIDCache: [String: CaptureIDCacheEntry] = [:]
    private struct PendingRecord {
        let level: RideDiagnosticLevel
        let category: RideDiagnosticCategory
        let event: String
        let fields: [String: String]
        let captureId: UUID?

        var isCritical: Bool {
            level == .warning || level == .error ||
                category == .user || category == .lifecycle
        }
    }
    private let pendingLock = NSLock()
    private var pendingRecords: [PendingRecord] = []
    private var pendingDrainScheduled = false
    private var pendingAdmissionDrops = 0
    private struct StorageOutcome {
        let event: String
        let fields: [String: String]
    }
    private var pendingStorageOutcomes: [StorageOutcome] = []
    private var isDrainingStorageOutcomes = false
    private struct ExportSnapshot: @unchecked Sendable {
        let rootURL: URL
        let healthData: Data
        let oldestWallTime: String?
        let newestWallTime: String?
        let exportedAt: String
        let appProcessID: String
        let captureID: String
        let retainedBytes: Int
        let droppedEventCount: Int
        let appVersion: String
        let appBuild: String
    }
    private struct PreparedExport: @unchecked Sendable {
        let snapshot: ExportSnapshot
        let outputURL: URL
        let staleCutoff: Date
    }

    private var exportSnapshotContainerURL: URL {
        rootURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".BicinoDiagnosticsExportSnapshots",
                isDirectory: true
            )
    }

    init(
        rootURL: URL? = nil,
        now: @escaping () -> Date = Date.init,
        userDefaults: UserDefaults = .standard
    ) {
        let initialCaptureID = UUID()
        let initializedAt = now()
        self.processId = UUID()
        self.standardCaptureId = initialCaptureID
        self.standardCaptureStartedAt = initializedAt
        self.captureBinding = RideDiagnosticsCaptureBinding(
            captureID: initialCaptureID,
            detailed: false
        )
        self.captureBindingSnapshot = RideDiagnosticsCaptureBinding(
            captureID: initialCaptureID,
            detailed: false
        )
        self.lastDeviceImportAt = nil
        self.oldestRetainedAt = nil
        self.newestRetainedAt = nil
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
        captureSnapshotLock.withLock { captureBindingSnapshot.captureID }
    }

    var currentCaptureIDString: String? {
        currentCaptureID?.uuidString.lowercased()
    }

    var isDetailedTraceEnabled: Bool {
        captureSnapshotLock.withLock { captureBindingSnapshot.detailed }
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
                    queueStorageOutcome(
                        event: "queue_dropped",
                        fields: ["droppedCount": String(admissionDrops)]
                    )
                }
                drainStorageOutcomes()
                return
            }
            pending = pendingRecords.removeFirst()
            pendingLock.unlock()

            if admissionDrops > 0 {
                totalDropped += admissionDrops
                publishDropCount()
                queueStorageOutcome(
                    event: "queue_dropped",
                    fields: ["droppedCount": String(admissionDrops)]
                )
            }
            drainStorageOutcomes()
            do {
                expireDetailedTraceIfNeeded()
                expireStandardCaptureIfNeeded()
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
                queueStorageOutcome(
                    event: "write_failed",
                    fields: ["reason": "storage_unavailable"]
                )
            }
        }
    }

    func beginDetailedTrace() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.detailedTraceActive else { return }
            self.expireStandardCaptureIfNeeded()
            self.preDetailedContextURL = self.currentChunkURL
            self.rotateChunk()
            self.activeCaptureId = UUID()
            let expiry = self.now().addingTimeInterval(4 * 60 * 60)
            self.detailedTraceExpiry = expiry
            self.detailedTraceActive = true
            self.publishCaptureState()
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
            self.endDetailedTraceOnQueue(reason: reason)
        }
    }

    /// Close the capture associated with the ride that just ended. Standard
    /// mode rotates too, so the fallback UUID never spans the app process and
    /// retention can enforce its age/count/byte bounds continuously.
    func endRideCapture() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.detailedTraceActive {
                self.endDetailedTraceOnQueue(reason: "ride_ended")
                return
            }
            self.recordOnQueue(
                level: .info,
                category: .lifecycle,
                event: "ride_capture_ended",
                fields: ["mode": "standard"]
            )
            self.rotateChunk()
            self.beginNewStandardCapture()
            self.flushOnQueue()
        }
    }

    @discardableResult
    func markIssue(_ code: RideIssueCode) -> Bool {
        queue.sync {
            expireDetailedTraceIfNeeded()
            expireStandardCaptureIfNeeded()
            let saved = recordOnQueue(
                level: .warning,
                category: .user,
                event: "issue_marker",
                fields: ["code": code.rawValue]
            )
            return saved && flushOnQueue()
        }
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
            importedDeviceChunkDataOnQueue(
                deviceDigest: deviceDigest,
                bootSequence: bootSequence,
                chunk: chunk,
                sha256: sha256
            )
        }
    }

    func importedDeviceChunkDataAsync(
        deviceDigest: String,
        bootSequence: UInt32,
        chunk: UInt32,
        sha256: String
    ) async -> Data? {
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Data?, Never>) in
            queue.async { [weak self] in
                continuation.resume(returning:
                    self?.importedDeviceChunkDataOnQueue(
                        deviceDigest: deviceDigest,
                        bootSequence: bootSequence,
                        chunk: chunk,
                        sha256: sha256
                    )
                )
            }
        }
    }

    private func importedDeviceChunkDataOnQueue(
        deviceDigest: String,
        bootSequence: UInt32,
        chunk: UInt32,
        sha256: String
    ) -> Data? {
        guard let url = importedChunkURL(
            deviceDigest: deviceDigest,
            bootSequence: bootSequence,
            chunk: chunk,
            sha256: sha256
        ) else { return nil }
        return try? Data(contentsOf: url)
    }

    func importDeviceRecorderHealth(
        deviceDigest: String,
        bootSequence: UInt32,
        data: Data,
        enforceRetention: Bool = true
    ) throws {
        try queue.sync {
            try importDeviceRecorderHealthOnQueue(
                deviceDigest: deviceDigest,
                bootSequence: bootSequence,
                data: data,
                enforceRetention: enforceRetention
            )
        }
    }

    func importDeviceRecorderHealthAsync(
        deviceDigest: String,
        bootSequence: UInt32,
        data: Data,
        enforceRetention: Bool = true
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing:
                        RideDiagnosticsError.unavailable(
                            "Diagnostic recorder is unavailable."
                        )
                    )
                    return
                }
                do {
                    try self.importDeviceRecorderHealthOnQueue(
                        deviceDigest: deviceDigest,
                        bootSequence: bootSequence,
                        data: data,
                        enforceRetention: enforceRetention
                    )
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func importDeviceRecorderHealthOnQueue(
        deviceDigest: String,
        bootSequence: UInt32,
        data: Data,
        enforceRetention: Bool
    ) throws {
        guard Self.isValidDeviceDigest(deviceDigest),
              bootSequence > 0, data.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Self.isValidDeviceRecorderHealth(
                object,
                expectedBootSequence: bootSequence
              ) else {
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
        let importedAt = now()
        lastDeviceImportAtOnQueue = importedAt
        publishLastDeviceImport(importedAt)
        if enforceRetention {
            updateRetainedBytes()
            try pruneRetention()
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
            try importDeviceChunkOnQueue(
                deviceDigest: deviceDigest,
                bootSequence: bootSequence,
                chunk: chunk,
                data: data,
                sha256: expectedHash,
                enforceRetention: enforceRetention
            )
        }
    }

    @discardableResult
    func importDeviceChunkAsync(
        deviceDigest: String,
        bootSequence: UInt32,
        chunk: UInt32,
        data: Data,
        sha256 expectedHash: String,
        enforceRetention: Bool = true
    ) async throws -> URL {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing:
                        RideDiagnosticsError.unavailable(
                            "Diagnostic recorder is unavailable."
                        )
                    )
                    return
                }
                do {
                    continuation.resume(returning:
                        try self.importDeviceChunkOnQueue(
                            deviceDigest: deviceDigest,
                            bootSequence: bootSequence,
                            chunk: chunk,
                            data: data,
                            sha256: expectedHash,
                            enforceRetention: enforceRetention
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func importDeviceChunkOnQueue(
        deviceDigest: String,
        bootSequence: UInt32,
        chunk: UInt32,
        data: Data,
        sha256 expectedHash: String,
        enforceRetention: Bool
    ) throws -> URL {
        guard Self.isValidDeviceDigest(deviceDigest),
              bootSequence > 0, chunk > 0,
              expectedHash.count == 64,
              expectedHash.allSatisfy({ $0.isHexDigit }),
              data.count <= Self.chunkLimit else {
            throw RideDiagnosticsError.unavailable(
                "The device chunk metadata is invalid."
            )
        }
        let actualHash = Self.sha256(data)
        guard actualHash == expectedHash.lowercased() else {
            throw RideDiagnosticsError.unavailable(
                "The device chunk hash did not match its index."
            )
        }
        let directory = rootURL
            .appendingPathComponent("imported-device", isDirectory: true)
            .appendingPathComponent(deviceDigest, isDirectory: true)
            .appendingPathComponent(String(bootSequence), isDirectory: true)
        let normalizedHash = expectedHash.lowercased()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            String(
                format: "events-%06u-%@.jsonl",
                chunk,
                String(normalizedHash.prefix(16))
            )
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
            updateRetainedBytes()
            try pruneRetention()
        }
        return url
    }

    func enforceRetention() throws {
        try queue.sync {
            try enforceRetentionOnQueue()
        }
    }

    func enforceRetentionAsync() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing:
                        RideDiagnosticsError.unavailable(
                            "Diagnostic recorder is unavailable."
                        )
                    )
                    return
                }
                do {
                    try self.enforceRetentionOnQueue()
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func enforceRetentionOnQueue() throws {
        updateRetainedBytes()
        try pruneRetention()
    }

    func flush() {
        queue.sync {
            _ = flushOnQueue()
        }
    }

    func exportBundle() throws -> URL {
        let prepared = try queue.sync { try prepareExportOnQueue() }
        return try Self.writePreparedExport(prepared)
    }

    func exportBundleAsync() async throws -> URL {
        let prepared: PreparedExport = try await withCheckedThrowingContinuation {
            continuation in
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else {
                    continuation.resume(
                        throwing: RideDiagnosticsError.unavailable(
                            "Diagnostic recorder is unavailable."
                        )
                    )
                    return
                }
                do {
                    continuation.resume(
                        returning: try self.prepareExportOnQueue()
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            queue.async(execute: workItem)
        }
        // CRC generation, archive writing, and the full byte-for-byte ZIP
        // validation are the expensive part of a maximum-size export. Run
        // them from the immutable Data snapshot without monopolizing the
        // recorder queue used by issue markers and lifecycle checkpoints.
        return try await Task.detached(priority: .userInitiated) {
            try Self.writePreparedExport(prepared)
        }.value
    }

#if HOST_TESTING
    func exportSourceStreamPathsForTesting() throws -> [String] {
        try queue.sync {
            let prepared = try prepareExportOnQueue()
            defer {
                try? FileManager.default.removeItem(
                    at: prepared.snapshot.rootURL
                )
            }
            return try Self.exportEntries(from: prepared.snapshot)
                .map(\.0)
                .filter { $0.hasSuffix(".jsonl") }
        }
    }
#endif

    func deleteLocalLogs() throws {
        try queue.sync {
            try? FileManager.default.removeItem(
                at: exportSnapshotContainerURL
            )
            try FileManager.default.removeItem(at: rootURL)
            captureIDCache.removeAll(keepingCapacity: true)
            try prepareStorage()
            sequence = 0
            chunkNumber = 1
            currentChunkURL = nil
            currentChunkBytes = 0
            preDetailedContextURL = nil
            activeCaptureId = nil
            detailedTraceActive = false
            detailedTraceExpiry = nil
            beginNewStandardCapture()
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
        // A process crash can occur after an immutable export snapshot is
        // staged but before the detached ZIP writer removes it. No export is
        // active while recorder storage initializes, so remove all orphaned
        // sibling snapshots before accepting new evidence.
        try? FileManager.default.removeItem(at: exportSnapshotContainerURL)
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
        lastDeviceImportAtOnQueue = allDiagnosticRetentionFiles()
            .filter { $0.lastPathComponent == "recorder-health.json" }
            .compactMap {
                try? $0.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate
            }
            .max()
        publishLastDeviceImport(lastDeviceImportAtOnQueue)
        // Keep the current process inventory durable even before the first
        // event reaches the recorder queue. Exports validate this sidecar
        // against the app stream and summary health, so a newly-created
        // recorder must never expose a missing manifest.
        try writeManifest(enforceRetention: false)
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

    @discardableResult
    private func recordOnQueue(
        level: RideDiagnosticLevel = .info,
        category: RideDiagnosticCategory,
        event: String,
        fields: [String: String]
    ) -> Bool {
        drainStorageOutcomes()
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
            return true
        } catch {
            totalDropped += 1
            publishDropCount()
            publishError(error.localizedDescription)
            queueStorageOutcome(
                event: "write_failed",
                fields: ["reason": "storage_unavailable"]
            )
            return false
        }
    }

    private func rotateChunk(recordOutcome: Bool = true) {
        let appDirectory = rootURL
            .appendingPathComponent("app", isDirectory: true)
            .appendingPathComponent(processId.uuidString.lowercased(), isDirectory: true)
        currentChunkURL = appDirectory.appendingPathComponent(
            String(format: "events-%06d.jsonl", chunkNumber)
        )
        chunkNumber += 1
        currentChunkBytes = 0
        if recordOutcome {
            queueStorageOutcome(
                event: "chunk_rotated",
                fields: ["chunk": String(chunkNumber - 1)]
            )
        }
    }

    @discardableResult
    private func flushOnQueue() -> Bool {
        drainStorageOutcomes()
        var synchronized = true
        if let currentChunkURL,
           FileManager.default.fileExists(atPath: currentChunkURL.path) {
            do {
                let handle = try FileHandle(forWritingTo: currentChunkURL)
                defer { try? handle.close() }
                try handle.synchronize()
            } catch {
                synchronized = false
                publishError(error.localizedDescription)
                queueStorageOutcome(
                    event: "write_failed",
                    fields: ["reason": "synchronize_failed"]
                )
            }
        }
        do {
            // A durability checkpoint must stay bounded. Append/import paths
            // enforce hard byte limits and schedule retention independently;
            // do not turn Mark Issue or app backgrounding into a full-corpus
            // capture graph scan.
            try writeManifest(enforceRetention: false)
        } catch {
            publishError(error.localizedDescription)
            queueStorageOutcome(
                event: "write_failed",
                fields: ["reason": "manifest_failed"]
            )
        }
        drainStorageOutcomes()
        return synchronized
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
        if enforceRetention {
            try pruneRetention()
        }
    }

    nonisolated private static func exportEntries(
        from snapshot: ExportSnapshot
    ) throws -> [(String, Data)] {
        let fileManager = FileManager.default
        var entries: [(String, Data)] = []
        let appRoot = snapshot.rootURL.appendingPathComponent(
            "app",
            isDirectory: true
        )
        if let files = fileManager.enumerator(at: appRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let file as URL in files {
                guard file.pathExtension == "jsonl" || file.pathExtension == "json" else { continue }
                guard let relative = archiveRelativePath(file, under: appRoot) else {
                    throw RideDiagnosticsError.invalidArchiveEntry
                }
                entries.append(("app/" + relative, try Data(contentsOf: file)))
            }
        }
        let importedRoot = snapshot.rootURL.appendingPathComponent(
            "imported-device",
            isDirectory: true
        )
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

        entries.append(("summary/recorder-health.json", snapshot.healthData))
        // FileManager enumeration order is unspecified. Metadata, manifest,
        // checksums, and ZIP layout all derive from this canonical order so
        // identical evidence and an injected fixed clock export identically.
        entries.sort { $0.0 < $1.0 }
        guard entries.allSatisfy({ isCanonicalExportMemberPath($0.0) }) else {
            throw RideDiagnosticsError.invalidArchiveEntry
        }
        for (path, data) in entries where path.hasSuffix(".json") {
            guard data.count <= 64 * 1024,
                  let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  isValidExportSidecar(path: path, object: object) else {
                throw RideDiagnosticsError.unavailable(
                    "Diagnostic sidecar \(path) contains malformed evidence."
                )
            }
        }
        let sourceStreams = entries.filter { $0.0.hasSuffix(".jsonl") }
        guard !sourceStreams.isEmpty else {
            throw RideDiagnosticsError.unavailable(
                "No complete diagnostic evidence is available to export."
            )
        }
        var captureIDs: Set<String> = []
        var firmwareIdentities: Set<String> = []
        var clockAnchorCount = 0
        var uptimeEventCount = 0
        var truncatedTailStreamCount = 0
        var truncatedStreamPaths: Set<String> = []
        var streamSequenceBounds: [String: (first: Int, last: Int)] = [:]
        var streamFirmwareIdentities: [String: String] = [:]
        var streamMetadata: [[String: Any]] = []
        for (path, data) in sourceStreams {
            var streamCaptures: Set<String> = []
            var streamAnchors: [[String: Any]] = []
            var firstSequence: Int?
            var lastSequence: Int?
            var previousSequence: Int?
            var source = "unknown"
            var streamFirmwareIdentity: String?
            var streamTruncated = false
            let expectedSource = path.hasPrefix("device/")
                ? "firmware"
                : "ios"
            var lines = data.split(
                separator: 0x0a,
                omittingEmptySubsequences: false
            )
            if data.last == 0x0a, lines.last?.isEmpty == true {
                lines.removeLast()
            } else if let tail = lines.last,
                      (try? JSONSerialization.jsonObject(with: Data(tail))) == nil {
                truncatedTailStreamCount += 1
                streamTruncated = true
                truncatedStreamPaths.insert(path)
                lines.removeLast()
            }
            var completeEventCount = 0
            for line in lines {
                guard !line.isEmpty,
                      line.count <= 8 * 1024,
                      let object = try? JSONSerialization.jsonObject(
                    with: Data(line)
                      ) as? [String: Any],
                      Self.isValidExportEvent(object) else {
                    throw RideDiagnosticsError.unavailable(
                        "Diagnostic stream \(path) contains malformed evidence."
                    )
                }
                completeEventCount += 1
                guard let eventSource = object["source"] as? String,
                      eventSource == expectedSource,
                      source == "unknown" || source == eventSource,
                      let sequence = object["sequence"] as? Int,
                      previousSequence == nil || sequence > previousSequence! else {
                    throw RideDiagnosticsError.unavailable(
                        "Diagnostic stream \(path) changes source or has a non-increasing sequence."
                    )
                }
                source = eventSource
                firstSequence = firstSequence ?? sequence
                lastSequence = sequence
                previousSequence = sequence
                if let capture = object["captureId"] as? String {
                    captureIDs.insert(capture)
                    streamCaptures.insert(capture)
                }
                if object["uptimeMs"] != nil {
                    uptimeEventCount += 1
                }
                if object["event"] as? String == "clock_anchor" {
                    clockAnchorCount += 1
                    var anchor: [String: Any] = [:]
                    if let wallTime = object["wallTime"] as? String {
                        anchor["wallTime"] = wallTime
                    }
                    if let uptime = object["uptimeMs"] as? NSNumber {
                        anchor["uptimeMs"] = uptime
                    }
                    if let fields = object["fields"] as? [String: Any] {
                        if let boot = fields["bootSequence"] as? NSNumber {
                            anchor["bootSequence"] = boot
                        }
                        if let fingerprint =
                            fields["firmwareFingerprint"] as? String {
                            anchor["firmwareFingerprint"] = fingerprint
                        }
                    }
                    streamAnchors.append(anchor)
                }
                if object["source"] as? String == "firmware",
                   let fields = object["fields"] as? [String: Any],
                   let boot = fields["bootSequence"] as? NSNumber,
                   let fingerprint = fields["firmwareFingerprint"] as? String {
                    let identity = "\(boot.uint64Value)|\(fingerprint.lowercased())"
                    guard streamFirmwareIdentity == nil ||
                            streamFirmwareIdentity == identity else {
                        throw RideDiagnosticsError.unavailable(
                            "Diagnostic stream \(path) changes firmware identity."
                        )
                    }
                    streamFirmwareIdentity = identity
                }
                if object["source"] as? String == "firmware",
                   let fields = object["fields"] as? [String: Any],
                   let target = fields["firmwareTarget"] as? String,
                   let fingerprint = fields["firmwareFingerprint"] as? String {
                    let build = (fields["firmwareBuild"] as? NSNumber)?
                        .stringValue ?? "unknown"
                    firmwareIdentities.insert(
                        "\(target)|\(build)|\(fingerprint)"
                    )
                }
            }
            guard completeEventCount > 0 else {
                throw RideDiagnosticsError.unavailable(
                    "Diagnostic stream \(path) contains no complete evidence."
                )
            }
            if let firstSequence, let lastSequence {
                streamSequenceBounds[path] = (firstSequence, lastSequence)
            }
            if let streamFirmwareIdentity {
                streamFirmwareIdentities[path] = streamFirmwareIdentity
            }
            streamMetadata.append([
                "path": path,
                "source": source,
                "bytes": data.count,
                "sha256": sha256(data),
                "captureIds": streamCaptures.sorted(),
                "firstSequence": (firstSequence as Any?) ?? NSNull(),
                "lastSequence": (lastSequence as Any?) ?? NSNull(),
                "truncatedTail": streamTruncated,
                "clockAnchors": streamAnchors,
            ])
        }
        let streamsByParent = Dictionary(grouping: sourceStreams.map(\.0)) {
            ($0 as NSString).deletingLastPathComponent
        }
        for (parent, paths) in streamsByParent {
            let ordered = paths.sorted()
            var previousLastSequence: Int?
            var previousFirmwareIdentity: String?
            var seenChunks: Set<Int> = []
            for (offset, path) in ordered.enumerated() {
                if offset < ordered.count - 1,
                   truncatedStreamPaths.contains(path) {
                    throw RideDiagnosticsError.unavailable(
                        "Diagnostic stream \(path) has a truncated tail before a later stream in \(parent)."
                    )
                }
                let filename = (path as NSString).lastPathComponent
                if filename.hasPrefix("events-") {
                    let suffix = filename.dropFirst("events-".count)
                    let digits = suffix.prefix { $0.isNumber }
                    if let chunk = Int(digits), !seenChunks.insert(chunk).inserted {
                        throw RideDiagnosticsError.unavailable(
                            "Diagnostic stream \(path) duplicates chunk \(chunk) in \(parent)."
                        )
                    }
                }
                if let bounds = streamSequenceBounds[path] {
                    if let previousLastSequence,
                       bounds.first <= previousLastSequence {
                        throw RideDiagnosticsError.unavailable(
                            "Diagnostic stream \(path) overlaps the previous chunk in \(parent)."
                        )
                    }
                    previousLastSequence = bounds.last
                }
                if let identity = streamFirmwareIdentities[path] {
                    if let previousFirmwareIdentity,
                       identity != previousFirmwareIdentity {
                        throw RideDiagnosticsError.unavailable(
                            "Diagnostic streams in \(parent) change firmware identity."
                        )
                    }
                    previousFirmwareIdentity = identity
                }
            }
        }
        var deviceDroppedEventCount = 0
        for (path, data) in entries
            where path.hasPrefix("device/") && path.hasSuffix(".json") {
            guard let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any],
                  let stats = object["stats"] as? [String: Any],
                  let dropped = stats["dropped"] as? NSNumber else { continue }
            deviceDroppedEventCount += dropped.intValue
        }
        let manifest: [String: Any] = [
            "schema": Self.schema,
            "manifestSchema": 1,
            "eventFormatSchema": Self.schema,
            "exportedAt": snapshot.exportedAt,
            "appProcessId": snapshot.appProcessID,
            "sourceStreams": sourceStreams.map(\.0),
            "streamMetadata": streamMetadata,
            "captureId": snapshot.captureID,
            "selectedCaptureRange": captureIDs.sorted(),
            "appBuildIdentity": [
                "version": snapshot.appVersion,
                "build": snapshot.appBuild,
            ],
            "firmwareBuildIdentities": firmwareIdentities.sorted(),
            "oldestWallTime": (snapshot.oldestWallTime as Any?) ?? NSNull(),
            "newestWallTime": (snapshot.newestWallTime as Any?) ?? NSNull(),
            "clockAnchorCount": clockAnchorCount,
            "uptimeEventCount": uptimeEventCount,
            "truncatedTailStreamCount": truncatedTailStreamCount,
            "retainedBytes": snapshot.retainedBytes,
            "droppedEventCount": snapshot.droppedEventCount,
            "deviceDroppedEventCount": deviceDroppedEventCount,
            "checksumAlgorithm": "sha256",
            "checksumFile": "checksums.sha256",
            "archiveValidation": "stored_zip_crc32_and_entry_bytes",
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

    private func prepareExportOnQueue() throws -> PreparedExport {
        guard flushOnQueue() else {
            throw RideDiagnosticsError.unavailable(
                "Diagnostic files could not be synchronized for export."
            )
        }
        let fileManager = FileManager.default
        // Close the mutable app chunk, then hard-link the retained evidence
        // into a same-volume immutable snapshot outside the recorder root.
        // File linking is bounded by
        // entry count; bulk reads, JSON validation, hashing, and ZIP work can
        // then run away from the sole recorder queue while new events append
        // to the next chunk. Keeping the snapshot outside rootURL ensures a
        // concurrent retention pass neither double-counts nor unlinks it.
        if currentChunkBytes > 0 {
            rotateChunk(recordOutcome: false)
        }
        let health = healthOnQueue()
        let healthData = try JSONEncoder.diagnosticsEncoder.encode(health)
        let exportedAt = isoFormatter.string(from: now())
        let captureID = (activeCaptureId ?? standardCaptureId)
            .uuidString.lowercased()
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "host"
        let appBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "unknown"
        let snapshotRoot = exportSnapshotContainerURL
            .appendingPathComponent(
                "snapshot-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        do {
            try fileManager.createDirectory(
                at: snapshotRoot,
                withIntermediateDirectories: true
            )
            applyFileProtection(to: snapshotRoot)
            for directoryName in ["app", "imported-device"] {
                let sourceRoot = rootURL.appendingPathComponent(
                    directoryName,
                    isDirectory: true
                )
                guard let files = fileManager.enumerator(
                    at: sourceRoot,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let file as URL in files {
                    guard file.pathExtension == "jsonl" ||
                            file.pathExtension == "json",
                          let relative = Self.archiveRelativePath(
                            file,
                            under: sourceRoot
                          ) else { continue }
                    let destination = snapshotRoot
                        .appendingPathComponent(
                            directoryName,
                            isDirectory: true
                        )
                        .appendingPathComponent(relative)
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    do {
                        try fileManager.linkItem(at: file, to: destination)
                    } catch {
                        // Same-volume hard links are expected under the
                        // recorder root. Retain a safe fallback for unusual
                        // simulator/filesystem configurations.
                        try fileManager.copyItem(at: file, to: destination)
                    }
                }
            }
        } catch {
            try? fileManager.removeItem(at: snapshotRoot)
            throw error
        }
        let snapshot = ExportSnapshot(
            rootURL: snapshotRoot,
            healthData: healthData,
            oldestWallTime: health.oldestWallTime,
            newestWallTime: health.newestWallTime,
            exportedAt: exportedAt,
            appProcessID: processId.uuidString.lowercased(),
            captureID: captureID,
            retainedBytes: retainedBytesOnQueue,
            droppedEventCount: totalDropped,
            appVersion: appVersion,
            appBuild: appBuild
        )
        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "BicinoDiagnosticsExports",
                isDirectory: true
            )
            .appendingPathComponent(exportFilename())
        let staleCutoff = now().addingTimeInterval(-24 * 60 * 60)
        return PreparedExport(
            snapshot: snapshot,
            outputURL: outputURL,
            staleCutoff: staleCutoff
        )
    }

    nonisolated private static func writePreparedExport(
        _ prepared: PreparedExport
    ) throws -> URL {
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: prepared.snapshot.rootURL) }
        let entries = try exportEntries(from: prepared.snapshot)
        let exportDirectory = prepared.outputURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true
        )
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: exportDirectory.path
        )
        for candidate in (try? fileManager.contentsOfDirectory(
            at: exportDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? [] where candidate.lastPathComponent.hasPrefix(
            "Bicino-Diagnostics-"
        ) && candidate.pathExtension == "zip" {
            let modified = try? candidate.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            if let modified, modified < prepared.staleCutoff {
                try? fileManager.removeItem(at: candidate)
            }
        }
        try? fileManager.removeItem(at: prepared.outputURL)
        do {
            try RideDiagnosticsStoredZipWriter.write(
                entries: entries,
                to: prepared.outputURL
            )
        } catch {
            try? fileManager.removeItem(at: prepared.outputURL)
            throw error
        }
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: prepared.outputURL.path
        )
        return prepared.outputURL
    }

    nonisolated private static func archiveRelativePath(
        _ file: URL,
        under root: URL
    ) -> String? {
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
            let isChunk = url.pathExtension == "jsonl" &&
                (resolvedPath.hasPrefix(importedPrefix) ||
                    resolvedPath.hasPrefix(appPrefix))
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
        let oldest = oldestEventDate()
        let newest = newestEventDate()
        DispatchQueue.main.async { [weak self] in
            self?.oldestRetainedAt = oldest
            self?.newestRetainedAt = newest
        }
    }

    private func captureIDs(in url: URL) -> Set<String> {
        if url.lastPathComponent == "recorder-health.json" ||
            url.lastPathComponent == "manifest.json" {
            // Sidecars describe a directory, not one capture. Treating their
            // union of sibling IDs as a graph edge makes every capture in a
            // long-lived app process or device boot one indivisible retention
            // component. Sidecars are pruned with their orphaned directory
            // instead and never participate in the capture-count graph.
            return []
        }
        let cacheKey = url.resolvingSymlinksInPath().standardizedFileURL.path
        let resourceValues = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey]
        )
        let bytes = resourceValues?.fileSize ?? -1
        let modifiedAt = resourceValues?.contentModificationDate
        if let cached = captureIDCache[cacheKey],
           cached.bytes == bytes,
           cached.modifiedAt == modifiedAt {
            return cached.captures
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
            let parentDigest = String(
                Self.sha256(Data(parentPath.utf8)).prefix(16)
            )
            captures.insert("uncorrelated:\(parentDigest)")
        }
        captureIDCache[cacheKey] = CaptureIDCacheEntry(
            bytes: bytes,
            modifiedAt: modifiedAt,
            captures: captures
        )
        return captures
    }

    private func pruneRetention(reserving requiredBytes: Int = 0) throws {
        let fileManager = FileManager.default
        var removedFiles = 0
        var removedBytes = 0
        var removalReasons: Set<String> = []
        func removeRetainedFile(_ url: URL, reason: String) throws {
            let bytes = (try? url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize) ?? 0
            try fileManager.removeItem(at: url)
            captureIDCache.removeValue(
                forKey: url.resolvingSymlinksInPath().standardizedFileURL.path
            )
            removedFiles += 1
            removedBytes += bytes
            removalReasons.insert(reason)
        }
        func removeOrphanedSidecars(reason: String) {
            let liveAppDirectory = rootURL
                .appendingPathComponent("app", isDirectory: true)
                .appendingPathComponent(
                    processId.uuidString.lowercased(),
                    isDirectory: true
                )
                .resolvingSymlinksInPath().standardizedFileURL.path
            for url in allDiagnosticRetentionFiles()
                where url.lastPathComponent == "recorder-health.json" ||
                    url.lastPathComponent == "manifest.json" {
                let directory = url.deletingLastPathComponent()
                let directoryPath = directory.resolvingSymlinksInPath()
                    .standardizedFileURL.path
                if url.lastPathComponent == "manifest.json" &&
                    directoryPath == liveAppDirectory {
                    continue
                }
                let siblings = (try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                if !siblings.contains(where: { $0.pathExtension == "jsonl" }) {
                    try? removeRetainedFile(url, reason: reason)
                    let remaining = (try? fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )) ?? []
                    if remaining.isEmpty {
                        try? fileManager.removeItem(at: directory)
                        let parent = directory.deletingLastPathComponent()
                        let parentEntries = (try? fileManager
                            .contentsOfDirectory(
                                at: parent,
                                includingPropertiesForKeys: nil,
                                options: [.skipsHiddenFiles]
                            )) ?? []
                        if parentEntries.isEmpty &&
                            parent.lastPathComponent != "app" &&
                            parent.lastPathComponent != "imported-device" {
                            try? fileManager.removeItem(at: parent)
                        }
                    }
                }
            }
        }
        let cutoff = now().addingTimeInterval(-Self.retentionAge)
        var files = allDiagnosticRetentionFiles()
        let activeCaptures = Set([
            (activeCaptureId ?? standardCaptureId).uuidString.lowercased()
        ])
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
        func captureComponents(
            in files: [URL],
            capturesByFile: [URL: Set<String>]
        ) -> [Set<String>] {
            var components: [Set<String>] = []
            for url in files {
                var joined = capturesByFile[url] ?? []
                guard !joined.isEmpty else { continue }
                var retained: [Set<String>] = []
                for component in components {
                    if component.isDisjoint(with: joined) {
                        retained.append(component)
                    } else {
                        joined.formUnion(component)
                    }
                }
                retained.append(joined)
                components = retained
            }
            return components
        }

        files = allDiagnosticChunkFiles()
        var capturesByFile = snapshot(files)
        let ageProtectedCaptureIDs = protectedCaptures(
            in: files,
            capturesByFile: capturesByFile
        )
        var ageDates: [String: Date] = [:]
        for url in files {
            let date = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? now()
            for capture in capturesByFile[url] ?? [] {
                ageDates[capture] = max(ageDates[capture] ?? .distantPast, date)
            }
        }
        let ageExpiredCaptureIDs = captureComponents(
            in: files,
            capturesByFile: capturesByFile
        ).filter { component in
            component.isDisjoint(with: ageProtectedCaptureIDs) &&
                (component.compactMap { ageDates[$0] }.max() ?? .distantPast) < cutoff
        }.reduce(into: Set<String>()) { expired, component in
            expired.formUnion(component)
        }
        if !ageExpiredCaptureIDs.isEmpty {
            for url in files where !isProtected(url, in: capturesByFile) {
                let captures = capturesByFile[url] ?? []
                if !captures.isEmpty,
                   captures.isSubset(of: ageExpiredCaptureIDs) {
                    try? removeRetainedFile(url, reason: "age")
                }
            }
        }
        removeOrphanedSidecars(reason: "age")

        files = allDiagnosticChunkFiles()
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
        let components = captureComponents(
            in: files,
            capturesByFile: capturesByFile
        ).filter { $0.isDisjoint(with: protectedCaptureIDs) }
            .sorted { left, right in
                let leftDate = left.compactMap { captureDates[$0] }.max() ?? .distantPast
                let rightDate = right.compactMap { captureDates[$0] }.max() ?? .distantPast
                return leftDate < rightDate
            }
        var remainingCaptureCount = captureDates.count
        var expiredCaptures: Set<String> = []
        for component in components
            where remainingCaptureCount > Self.retainedCaptureLimit {
            // Files are atomic retention components. Remove the oldest whole
            // component even when that overshoots the exact excess; otherwise
            // one 21-ID imported chunk can defeat the hard 20-capture cap.
            expiredCaptures.formUnion(component)
            remainingCaptureCount -= component.count
        }
        if !expiredCaptures.isEmpty {
            for url in files where !isProtected(url, in: capturesByFile) {
                let captures = capturesByFile[url] ?? []
                if !captures.isEmpty,
                   captures.isSubset(of: expiredCaptures) {
                    try? removeRetainedFile(url, reason: "capture_count")
                }
            }
        }
        removeOrphanedSidecars(reason: "capture_count")

        updateRetainedBytes()
        files = allDiagnosticChunkFiles()
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
            let deletableComponents = captureComponents(
                in: files,
                capturesByFile: capturesByFile
            ).filter {
                !$0.isEmpty &&
                    $0.isDisjoint(with: protectedCaptureIDs)
            }
            guard let oldestComponent = deletableComponents.min(by: { left, right in
                let leftDate = left.compactMap { dates[$0] }.max() ?? .distantPast
                let rightDate = right.compactMap { dates[$0] }.max() ?? .distantPast
                return leftDate < rightDate
            }) else {
                let sidecars = allDiagnosticRetentionFiles().filter {
                    $0.pathExtension != "jsonl" &&
                        !protectedPaths.contains(
                            $0.resolvingSymlinksInPath().standardizedFileURL.path
                        )
                }
                guard let oldestSidecar = sidecars.min(by: { left, right in
                    let leftDate = (try? left.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate) ?? .distantPast
                    let rightDate = (try? right.resourceValues(
                        forKeys: [.contentModificationDateKey]
                    ).contentModificationDate) ?? .distantPast
                    return leftDate < rightDate
                }) else { break }
                try removeRetainedFile(oldestSidecar, reason: "byte_limit")
                updateRetainedBytes()
                files = allDiagnosticChunkFiles()
                continue
            }
            let candidates = files.filter {
                let captures = capturesByFile[$0] ?? []
                return !isProtected($0, in: capturesByFile) &&
                    !captures.isEmpty &&
                    captures.isSubset(of: oldestComponent)
            }
            guard !candidates.isEmpty else { break }
            for candidate in candidates {
                try removeRetainedFile(candidate, reason: "byte_limit")
            }
            removeOrphanedSidecars(reason: "byte_limit")
            files = allDiagnosticChunkFiles()
            updateRetainedBytes()
        }
        updateRetainedBytes()
        if removedFiles > 0 {
            queueStorageOutcome(
                event: "retention_pruned",
                fields: [
                    "eventCount": String(removedFiles),
                    "bytes": String(removedBytes),
                    "reason": removalReasons.sorted().joined(separator: "+"),
                ]
            )
        }
    }

    private func oldestEventDate() -> Date? {
        allDiagnosticChunkFiles().compactMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }.min()
    }

    private func healthOnQueue() -> RideDiagnosticsRecorderHealth {
        let captureCount = Set(
            allDiagnosticChunkFiles().flatMap { captureIDs(in: $0) }
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
            lastError: lastErrorOnQueue,
            detailedTraceEnabled: detailedTraceActive,
            detailedTraceExpiresAt: detailedTraceExpiry.map(isoFormatter.string)
        )
    }

    private func newestEventDate() -> Date? {
        allDiagnosticChunkFiles().compactMap { url in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }.max()
    }

    private func expireDetailedTraceIfNeeded(force: Bool = false) {
        guard detailedTraceActive,
              let expires = detailedTraceExpiry,
              (force || now() >= expires) else { return }
        endDetailedTraceOnQueue(reason: "time_limit")
    }

    private func endDetailedTraceOnQueue(reason: String) {
        guard detailedTraceActive else { return }
        recordOnQueue(
            level: .info,
            category: .user,
            event: "detailed_trace_ended",
            fields: ["reason": Self.safeEnum(reason)]
        )
        rotateChunk()
        activeCaptureId = nil
        preDetailedContextURL = nil
        detailedTraceExpiry = nil
        detailedTraceActive = false
        beginNewStandardCapture()
        flushOnQueue()
    }

    private func expireStandardCaptureIfNeeded() {
        guard !detailedTraceActive,
              now().timeIntervalSince(standardCaptureStartedAt) >= 4 * 60 * 60
        else { return }
        recordOnQueue(
            level: .info,
            category: .lifecycle,
            event: "standard_capture_ended",
            fields: ["reason": "time_limit"]
        )
        rotateChunk()
        beginNewStandardCapture()
    }

    private func beginNewStandardCapture() {
        standardCaptureId = UUID()
        standardCaptureStartedAt = now()
        publishCaptureState()
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

    private func queueStorageOutcome(
        event: String,
        fields: [String: String]
    ) {
        guard pendingStorageOutcomes.count < 32 else { return }
        pendingStorageOutcomes.append(
            StorageOutcome(
                event: Self.safeEventName(event),
                fields: Self.sanitize(fields: fields)
            )
        )
    }

    private func drainStorageOutcomes() {
        guard !isDrainingStorageOutcomes else { return }
        isDrainingStorageOutcomes = true
        defer { isDrainingStorageOutcomes = false }
        var drained = 0
        while !pendingStorageOutcomes.isEmpty && drained < 32 {
            let outcome = pendingStorageOutcomes.removeFirst()
            let diagnosticEvent = RideDiagnosticEvent(
                schema: Self.schema,
                source: "ios",
                sequence: sequence,
                level: .info,
                category: .storage,
                event: outcome.event,
                wallTime: isoFormatter.string(from: now()),
                uptimeMs: max(
                    0,
                    Int(
                        (ProcessInfo.processInfo.systemUptime - startUptime) *
                            1000
                    )
                ),
                processId: processId.uuidString.lowercased(),
                captureId: (activeCaptureId ?? standardCaptureId)
                    .uuidString.lowercased(),
                fields: outcome.fields
            )
            sequence += 1
            do {
                try append(diagnosticEvent)
                publish(diagnosticEvent)
            } catch {
                sequence -= 1
                pendingStorageOutcomes.insert(outcome, at: 0)
                publishError(error.localizedDescription)
                break
            }
            drained += 1
        }
    }

    private func publishRetainedBytes(_ bytes: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.retainedBytes = bytes
        }
    }

    private func publishDropCount() {
        let count = totalDropped
        DispatchQueue.main.async { [weak self] in
            self?.droppedEventCount = count
        }
    }

    private func publishCaptureState() {
        let enabled = detailedTraceActive
        let expiry = detailedTraceExpiry
        let binding = RideDiagnosticsCaptureBinding(
            captureID: activeCaptureId ?? standardCaptureId,
            detailed: enabled
        )
        captureSnapshotLock.withLock {
            captureBindingSnapshot = binding
        }
        DispatchQueue.main.async { [weak self] in
            self?.detailedTraceEnabled = enabled
            self?.detailedTraceExpiresAt = expiry
            self?.captureBinding = binding
        }
    }

    private func publishLastDeviceImport(_ date: Date?) {
        DispatchQueue.main.async { [weak self] in
            self?.lastDeviceImportAt = date
        }
    }

    private func publishError(_ message: String) {
        let snapshot = String(message.prefix(160))
        lastErrorOnQueue = snapshot
        DispatchQueue.main.async { [weak self] in
            self?.lastError = snapshot
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

    nonisolated private static func isValidExportEvent(
        _ object: [String: Any]
    ) -> Bool {
        let required: Set<String> = [
            "schema", "source", "sequence", "level", "category", "event",
        ]
        let allowed = required.union([
            "wallTime", "uptimeMs", "processId", "captureId", "fields",
        ])
        guard required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: allowed),
              !isJSONBoolean(object["schema"]),
              object["schema"] as? Int == Self.schema,
              let source = object["source"] as? String,
              ["ios", "firmware", "host"].contains(source),
              !isJSONBoolean(object["sequence"]),
              let sequence = object["sequence"] as? Int,
              sequence >= 0,
              let level = object["level"] as? String,
              RideDiagnosticLevel(rawValue: level) != nil,
              let category = object["category"] as? String,
              RideDiagnosticCategory(rawValue: category) != nil,
              let event = object["event"] as? String,
              !event.isEmpty,
              event.utf8.count <= 64 else { return false }
        if let wallTime = object["wallTime"] {
            guard let value = wallTime as? String else { return false }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [
                .withInternetDateTime, .withFractionalSeconds,
            ]
            let seconds = ISO8601DateFormatter()
            seconds.formatOptions = [.withInternetDateTime]
            guard fractional.date(from: value) != nil ||
                    seconds.date(from: value) != nil else { return false }
        }
        if let uptime = object["uptimeMs"] {
            guard !isJSONBoolean(uptime),
                  let value = uptime as? Int,
                  value >= 0 else { return false }
        }
        for key in ["processId", "captureId"] {
            if let identifier = object[key] {
                guard let value = identifier as? String,
                      value.utf8.count == 36,
                      UUID(uuidString: value) != nil else { return false }
            }
        }
        if let fieldsValue = object["fields"] {
            guard let fields = fieldsValue as? [String: Any],
                  fields.count <= 32 else { return false }
            for (key, value) in fields {
                guard RideDiagnosticsFieldPolicy.isAllowed(key),
                      !(value is [String: Any]),
                      !(value is [Any]),
                      isPrivacySafeImportedJSON(value) else { return false }
            }
        }
        let fields = object["fields"] as? [String: Any] ?? [:]
        if source == "ios" {
            guard fields.values.allSatisfy({ $0 is String }) else {
                return false
            }
        } else if source == "firmware" {
            guard fields.allSatisfy({
                RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(
                    key: $0.key,
                    value: $0.value
                )
            }),
            let boot = fields["bootSequence"] as? NSNumber,
            !RideDiagnosticsFieldPolicy.isJSONBoolean(boot),
            boot.uint64Value > 0,
            boot.uint64Value <= UInt64(UInt32.max),
            let fingerprint = fields["firmwareFingerprint"] as? String,
            fingerprint.utf8.count == 8,
            fingerprint.allSatisfy(\.isHexDigit) else { return false }
        }
        return true
    }

    nonisolated private static func isJSONBoolean(_ value: Any?) -> Bool {
        RideDiagnosticsFieldPolicy.isJSONBoolean(value)
    }

    nonisolated private static func isNonnegativeJSONInteger(
        _ value: Any?,
        maximum: UInt64 = UInt64.max
    ) -> Bool {
        guard !isJSONBoolean(value), let number = value as? NSNumber else {
            return false
        }
        let doubleValue = number.doubleValue
        return doubleValue.isFinite && doubleValue >= 0 &&
            doubleValue.rounded(.towardZero) == doubleValue &&
            number.uint64Value <= maximum
    }

    nonisolated private static func isTimestampOrNull(_ value: Any?) -> Bool {
        if value is NSNull { return true }
        guard let value = value as? String else { return false }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime, .withFractionalSeconds,
        ]
        let seconds = ISO8601DateFormatter()
        seconds.formatOptions = [.withInternetDateTime]
        return fractional.date(from: value) != nil ||
            seconds.date(from: value) != nil
    }

    nonisolated private static func isValidDeviceRecorderHealth(
        _ object: [String: Any],
        expectedBootSequence: UInt32
    ) -> Bool {
        let required: Set<String> = [
            "schema", "source", "bootSequence", "activeChunk", "stats",
            "chunks",
        ]
        guard Set(object.keys) == required,
              !isJSONBoolean(object["schema"]),
              object["schema"] as? Int == Self.schema,
              object["source"] as? String == "firmware",
              isNonnegativeJSONInteger(
                object["bootSequence"],
                maximum: UInt64(UInt32.max)
              ),
              (object["bootSequence"] as? NSNumber)?.uint32Value ==
                expectedBootSequence,
              isNonnegativeJSONInteger(
                object["activeChunk"],
                maximum: UInt64(UInt32.max)
              ),
              ((object["activeChunk"] as? NSNumber)?.uint32Value ?? 0) > 0,
              let stats = object["stats"] as? [String: Any],
              Set(stats.keys) == [
                "enqueued", "written", "dropped", "storageErrors",
              ],
              stats.values.allSatisfy({
                isNonnegativeJSONInteger($0, maximum: UInt64(UInt32.max))
              }),
              let chunks = object["chunks"] as? [[String: Any]],
              chunks.count <= 256,
              isPrivacySafeImportedJSON(object) else { return false }
        var identities: Set<String> = []
        for chunk in chunks {
            guard Set(chunk.keys) == [
                "bootSequence", "chunk", "bytes", "sha256",
            ],
            isNonnegativeJSONInteger(
                chunk["bootSequence"], maximum: UInt64(UInt32.max)
            ),
            let chunkBoot = (chunk["bootSequence"] as? NSNumber)?.uint32Value,
            chunkBoot > 0,
            chunkBoot <= expectedBootSequence,
            isNonnegativeJSONInteger(
                chunk["chunk"], maximum: UInt64(UInt32.max)
            ),
            let chunkNumber = (chunk["chunk"] as? NSNumber)?.uint32Value,
            chunkNumber > 0,
            isNonnegativeJSONInteger(chunk["bytes"], maximum: 256 * 1024),
            ((chunk["bytes"] as? NSNumber)?.intValue ?? 0) > 0,
            let sha256 = chunk["sha256"] as? String,
            sha256.utf8.count == 64,
            sha256.allSatisfy(\.isHexDigit) else { return false }
            guard identities.insert("\(chunkBoot):\(chunkNumber)").inserted else {
                return false
            }
        }
        return true
    }

    nonisolated private static func isValidExportSidecar(
        path: String,
        object: [String: Any]
    ) -> Bool {
        if path == "summary/recorder-health.json" {
            let required: Set<String> = [
                "schema", "processId", "retainedBytes",
                "retainedChunkCount", "retainedCaptureCount",
                "oldestWallTime", "newestWallTime", "droppedEventCount",
                "lastError", "detailedTraceEnabled",
                "detailedTraceExpiresAt",
            ]
            guard Set(object.keys) == required,
                  !isJSONBoolean(object["schema"]),
                  object["schema"] as? Int == Self.schema,
                  let processID = object["processId"] as? String,
                  UUID(uuidString: processID) != nil,
                  [
                    "retainedBytes", "retainedChunkCount",
                    "retainedCaptureCount", "droppedEventCount",
                  ].allSatisfy({ isNonnegativeJSONInteger(object[$0]) }),
                  isTimestampOrNull(object["oldestWallTime"]),
                  isTimestampOrNull(object["newestWallTime"]),
                  isTimestampOrNull(object["detailedTraceExpiresAt"]),
                  object["lastError"] is NSNull ||
                    object["lastError"] is String,
                  isJSONBoolean(object["detailedTraceEnabled"]),
                  isPrivacySafeImportedJSON(object) else { return false }
            return true
        }
        let components = path.split(separator: "/")
        if components.count == 3,
           components[0] == "app",
           components[2] == "manifest.json" {
            let required: Set<String> = [
                "schema", "source", "processId", "createdAt",
                "chunkLimitBytes", "retentionBytes",
                "retentionCaptureCount", "retentionAgeDays",
                "droppedEventCount",
            ]
            guard Set(object.keys) == required,
                  !isJSONBoolean(object["schema"]),
                  object["schema"] as? Int == Self.schema,
                  object["source"] as? String == "ios",
                  let processID = object["processId"] as? String,
                  processID == String(components[1]),
                  UUID(uuidString: processID) != nil,
                  isTimestampOrNull(object["createdAt"]),
                  [
                    "chunkLimitBytes", "retentionBytes",
                    "retentionCaptureCount", "retentionAgeDays",
                  ].allSatisfy({
                    isNonnegativeJSONInteger(object[$0]) &&
                        ((object[$0] as? NSNumber)?.uint64Value ?? 0) > 0
                  }),
                  isNonnegativeJSONInteger(object["droppedEventCount"]),
                  isPrivacySafeImportedJSON(object) else { return false }
            return true
        }
        if components.count == 4,
           components[0] == "device",
           components[3] == "recorder-health.json",
           let bootSequence = UInt32(components[2]) {
            return isValidDeviceRecorderHealth(
                object,
                expectedBootSequence: bootSequence
            )
        }
        return false
    }

    nonisolated private static func isCanonicalExportMemberPath(
        _ path: String
    ) -> Bool {
        if path == "summary/recorder-health.json" { return true }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty }) else { return false }
        if components.count == 3, components[0] == "app" {
            let process = String(components[1])
            guard UUID(uuidString: process)?.uuidString.lowercased() == process else {
                return false
            }
            let filename = String(components[2])
            if filename == "manifest.json" { return true }
            return isCanonicalChunkFilename(
                filename,
                requiresHashSuffix: false
            )
        }
        if components.count == 4, components[0] == "device" {
            let digest = String(components[1])
            guard digest.utf8.count == 16,
                  digest.unicodeScalars.allSatisfy({
                    (48...57).contains($0.value) || (97...102).contains($0.value)
                  }),
                  let boot = UInt32(components[2]),
                  boot > 0,
                  String(boot) == String(components[2]) else { return false }
            let filename = String(components[3])
            if filename == "recorder-health.json" { return true }
            return isCanonicalChunkFilename(filename, requiresHashSuffix: true)
        }
        return false
    }

    nonisolated private static func isCanonicalChunkFilename(
        _ filename: String,
        requiresHashSuffix: Bool
    ) -> Bool {
        guard filename.hasPrefix("events-"), filename.hasSuffix(".jsonl") else {
            return false
        }
        let body = String(filename.dropFirst(7).dropLast(6))
        let components = body.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == (requiresHashSuffix ? 2 : 1),
              components[0].utf8.count == 6,
              components[0].unicodeScalars.allSatisfy({
                (48...57).contains($0.value)
              }),
              let chunk = UInt32(components[0]), chunk > 0 else { return false }
        if requiresHashSuffix {
            let digest = components[1]
            return digest.utf8.count == 16 && digest.unicodeScalars.allSatisfy {
                (48...57).contains($0.value) || (97...102).contains($0.value)
            }
        }
        return true
    }

    nonisolated private static func isPrivacySafeImportedJSON(
        _ value: Any,
        depth: Int = 0
    ) -> Bool {
        guard depth <= 8 else { return false }
        let structuralKeys: Set<String> = [
            "schema", "source", "bootSequence", "activeChunk", "stats",
            "enqueued", "written", "dropped", "storageErrors", "chunks",
            "chunk", "bytes", "sha256", "processId", "createdAt",
            "chunkLimitBytes", "retentionBytes", "retentionCaptureCount",
            "retentionAgeDays", "droppedEventCount", "retainedChunkCount",
            "retainedBytes", "retainedCaptureCount", "oldestWallTime", "newestWallTime",
            "lastError", "detailedTraceEnabled", "detailedTraceExpiresAt",
        ]
        let forbidden = [
            "latitude", "longitude", "coordinate", "address",
            "instruction", "destination", "password", "passphrase",
            "secret", "apikey", "api_key", "credential", "token",
            "ownerkey", "healthkit", "heartrate",
            "heart_rate", "rawimu", "raw_imu", "payload",
        ]
        if let dictionary = value as? [String: Any] {
            guard dictionary.count <= 32 else { return false }
            return dictionary.allSatisfy { key, child in
                let normalized = key.replacingOccurrences(
                    of: "-",
                    with: "_"
                ).lowercased()
                return (structuralKeys.contains(key) ||
                        RideDiagnosticsFieldPolicy.isAllowed(key)) &&
                    !forbidden.contains(where: { normalized.contains($0) }) &&
                    isPrivacySafeImportedJSON(child, depth: depth + 1)
            }
        }
        if let array = value as? [Any] {
            return array.count <= 256 && array.allSatisfy {
                isPrivacySafeImportedJSON($0, depth: depth + 1)
            }
        }
        if let string = value as? String {
            let normalized = string.lowercased()
            return string.utf8.count <= 256 &&
                !normalized.contains("bearer ") &&
                !normalized.contains("x-bikecomputer-transfer-token")
        }
        return value is NSNumber || value is NSNull
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
            "destination", "password", "passphrase", "secret", "apikey",
            "api_key", "credential", "token", "ownerkey",
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

    nonisolated private static func sha256(_ data: Data) -> String {
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
