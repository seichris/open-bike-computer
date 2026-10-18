import Foundation

nonisolated struct DiagnosticsCaptureRequest: Codable, Equatable, Sendable {
    let captureID: UUID
    let generation: UInt32
    let mask: UInt32
    let minimumLevel: UInt32
    let durationSeconds: UInt32
    let budgetBytes: UInt32

    var valid: Bool {
        generation > 0 && mask != 0 && mask & ~DiagnosticsSchema.instrumentedMask == 0 &&
            minimumLevel < 6 && durationSeconds > 0 && durationSeconds <= 14_400 &&
            budgetBytes >= 1024 && budgetBytes <= 32 * 1024 * 1024
    }
    var command: String {
        "policy|2|\(captureID.uuidString.lowercased())|\(generation)|\(mask)|\(minimumLevel)|\(durationSeconds)|\(budgetBytes)|\(DiagnosticsSchema.digest)"
    }
}

nonisolated struct DiagnosticsCapturePolicyState: Sendable {
    private(set) var request: DiagnosticsCaptureRequest?
    private(set) var expiresUptime: TimeInterval = 0
    private(set) var remainingBytes: UInt32 = 0
    private(set) var filteredCount: UInt64 = 0

    mutating func apply(_ next: DiagnosticsCaptureRequest, now: TimeInterval, captureID: UUID) -> Bool {
        guard now.isFinite, next.valid, next.captureID == captureID else { return false }
        if let old = request, old.captureID == next.captureID {
            if old.generation == next.generation { return old == next }
            if old.generation > next.generation { return false }
        }
        request = next
        expiresUptime = now + Double(next.durationSeconds)
        remainingBytes = next.budgetBytes
        filteredCount = 0
        return true
    }
    func active(now: TimeInterval, captureID: UUID) -> Bool {
        request?.captureID == captureID && remainingBytes > 0 && now < expiresUptime
    }
    mutating func admit(level: String, domain: String, now: TimeInterval,
                        captureID: UUID, maximumBytes: UInt32) -> Bool {
        guard let rank = DiagnosticsSchema.levels.firstIndex(of: level) else { return false }
        if rank >= 2 { return true } // baseline survives filtering and exhausted budget
        guard let request, active(now: now, captureID: captureID),
              request.mask & DiagnosticsSchema.mask(for: domain) != 0,
              rank >= request.minimumLevel, remainingBytes >= maximumBytes else {
            if filteredCount < UInt64.max { filteredCount += 1 }
            return false
        }
        remainingBytes -= maximumBytes
        return true
    }
}

/// Observed device acknowledgement, not an inference from a queued BLE write.
nonisolated struct DiagnosticsCaptureStatus: Codable, Equatable, Sendable {
    let schema: Int
    let schemaDigest: String
    let supportedMask: UInt32
    let generation: UInt32
    let mask: UInt32
    let minimumLevel: UInt32
    let active: Bool
    let captureId: String
    let remainingBytes: UInt32
    let filteredCount: UInt32
    let deadlineUptimeMs: UInt32
    let baselineMinimumLevel: UInt32
    let rawPayloads: Bool

    var valid: Bool {
        schema == 2 && schemaDigest.count == 64 &&
            schemaDigest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } &&
            mask & ~supportedMask == 0 && minimumLevel <= 5 && baselineMinimumLevel == 2 &&
            remainingBytes <= 32 * 1024 * 1024 && !rawPayloads &&
            (captureId.isEmpty ? generation == 0 && !active : UUID(uuidString: captureId) != nil)
    }
    func acknowledges(_ request: DiagnosticsCaptureRequest) -> Bool {
        valid && schemaDigest == DiagnosticsSchema.digest && active &&
            generation == request.generation && mask == request.mask &&
            minimumLevel == request.minimumLevel && captureId == request.captureID.uuidString.lowercased()
    }
}
