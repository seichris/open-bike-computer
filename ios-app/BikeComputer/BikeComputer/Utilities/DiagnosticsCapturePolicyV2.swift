import Foundation

/// Persistent, bounded owner request. Expiry is absolute as well as monotonic
/// at the producer, so a reconnect/reboot cannot renew an old capture lease.
nonisolated struct DiagnosticsCapturePolicyV2: Codable, Equatable, Sendable {
    let schema: Int
    let captureID: UUID
    let generation: UInt32
    let profile: String
    let createdAt: Date
    let expiresAt: Date
    let durationSeconds: UInt32
    let levels: [String: String]

    init(captureID: UUID = UUID(), generation: UInt32 = 1,
         profile: String, durationSeconds: UInt32,
         levels: [String: String]? = nil, now: Date = Date()) throws {
        guard generation > 0,
              durationSeconds <= DiagnosticsContractV2.maximumCaptureSeconds,
              let selected = levels ?? DiagnosticsContractV2.profiles[profile],
              selected.allSatisfy({ DiagnosticsContractV2.domains.contains($0.key) &&
                  DiagnosticsContractV2.levels.contains($0.value) }),
              durationSeconds > 0 || selected.values.allSatisfy({
                  (DiagnosticsContractV2.levels.firstIndex(of: $0) ?? 0) >= 2
              }) else { throw DiagnosticsPolicyError.invalidPolicy }
        self.schema = 2
        self.captureID = captureID
        self.generation = generation
        self.profile = profile
        self.createdAt = now
        self.expiresAt = now.addingTimeInterval(TimeInterval(durationSeconds))
        self.durationSeconds = durationSeconds
        self.levels = selected
    }

    var valid: Bool {
        schema == 2 && generation > 0 &&
        durationSeconds <= DiagnosticsContractV2.maximumCaptureSeconds &&
        expiresAt.timeIntervalSince(createdAt) == TimeInterval(durationSeconds) &&
        levels.allSatisfy { DiagnosticsContractV2.domains.contains($0.key) &&
            DiagnosticsContractV2.levels.contains($0.value) } &&
        (durationSeconds > 0 || levels.values.allSatisfy {
            (DiagnosticsContractV2.levels.firstIndex(of: $0) ?? 0) >= 2
        })
    }

    func effectiveLevels(at now: Date) -> [String: String] {
        guard valid, durationSeconds > 0, now < expiresAt else { return [:] }
        return levels
    }

    func command() throws -> String {
        guard valid, createdAt.timeIntervalSince1970 >= 1_700_000_000,
              expiresAt.timeIntervalSince1970 < Double(UInt32.max) else {
            throw DiagnosticsPolicyError.invalidPolicy
        }
        let vector = DiagnosticsContractV2.domains.map {
            String(DiagnosticsContractV2.levels.firstIndex(of: levels[$0] ?? "info") ?? 2)
        }.joined()
        let expiry = durationSeconds == 0 ? 0 : UInt32(expiresAt.timeIntervalSince1970.rounded(.down))
        return "DTRNcapture|2|\(captureID.uuidString.lowercased())|\(generation)|\(durationSeconds)|\(expiry)|\(vector)"
    }
}

nonisolated enum DiagnosticsPolicyError: Error {
    case invalidPolicy
    case unsupported
    case acknowledgementTimeout
    case deviceChanged
}

/// A firmware acknowledgement is a capability/effective-policy receipt, not
/// proof of durable event storage. Keep those two boundaries separate.
nonisolated struct DeviceDiagnosticsStatusV2: Codable, Equatable, Sendable {
    let schema: Int
    let contractSHA256: String
    let captureID: String
    let generation: UInt32
    let effectiveLevels: String
    let remainingSeconds: UInt32
    let filtered: UInt32
    let rateLimited: UInt32
    let durableSequence: UInt32
    let markerQueued: UInt32
    let markerDurable: UInt32
    let policyPersisted: Bool
    let detailedAutomationAvailable: Bool
    let crashAvailable: Bool

    var valid: Bool {
        schema == 2 && contractSHA256 == DiagnosticsContractV2.sha256 &&
        (captureID.isEmpty || UUID(uuidString: captureID) != nil) &&
        effectiveLevels.count == DiagnosticsContractV2.domains.count &&
        effectiveLevels.allSatisfy { "012345".contains($0) } &&
        remainingSeconds <= DiagnosticsContractV2.maximumCaptureSeconds &&
        markerDurable <= markerQueued
    }
    func acknowledges(_ request: DiagnosticsCapturePolicyV2) -> Bool {
        valid && captureID == request.captureID.uuidString.lowercased() &&
        generation == request.generation &&
        effectiveLevels == DiagnosticsContractV2.domains.map {
            String(DiagnosticsContractV2.levels.firstIndex(of: request.levels[$0] ?? "info") ?? 2)
        }.joined() && (request.durationSeconds == 0 || remainingSeconds > 0)
    }
}

/// Recorder-owned value; call while holding the recorder's policy lock.
nonisolated struct DiagnosticsAdmissionV2 {
    var policy: DiagnosticsCapturePolicyV2?
    private(set) var filtered = 0
    private(set) var rateLimited = 0
    private var leaseDeadline: TimeInterval?
    private var windowStarted: TimeInterval = 0
    private var events = 0
    private var bytes = 0

    mutating func install(_ request: DiagnosticsCapturePolicyV2, now: Date, uptime: TimeInterval) {
        policy = request
        leaseDeadline = uptime + max(0, min(TimeInterval(request.durationSeconds), request.expiresAt.timeIntervalSince(now)))
    }

    mutating func admit(level: String, domain: String, estimatedBytes: Int,
                        now: Date, uptime: TimeInterval) -> Bool {
        let severity = DiagnosticsContractV2.levels.firstIndex(of: level) ?? 2
        if severity >= 3 || ["logger", "boot", "lifecycle", "user"].contains(domain) { return true }
        let liveLease = leaseDeadline.map { uptime < $0 } ?? true
        let requested = liveLease ? (policy?.effectiveLevels(at: now)[domain] ?? "info") : "info"
        let threshold = DiagnosticsContractV2.levels.firstIndex(of: requested) ?? 2
        guard severity >= threshold else { filtered += 1; return false }
        if severity >= 2 { return true }
        if uptime < windowStarted || uptime - windowStarted >= 1 {
            windowStarted = uptime; events = 0; bytes = 0
        }
        guard events < 20, estimatedBytes >= 0, estimatedBytes <= 8192 - bytes else {
            rateLimited += 1; return false
        }
        events += 1; bytes += estimatedBytes
        return true
    }
}
