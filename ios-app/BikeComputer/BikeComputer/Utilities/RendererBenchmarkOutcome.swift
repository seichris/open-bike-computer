import Foundation

/// Execution, cleanup and export are separate outcomes. A selected candidate
/// or a successful soak must never erase a failed comparison.
nonisolated enum RendererBenchmarkExecutionOutcome: String, Codable, Sendable {
    case completed
    case userCancelled = "user_cancelled"
    case lifecycleCancelled = "lifecycle_cancelled"
    case transportAborted = "transport_aborted"
    case executionAborted = "execution_aborted"
}

nonisolated enum RendererBenchmarkStopReason: String, Codable, Sendable {
    case user
    case lifecycle
    case transport

    var executionOutcome: RendererBenchmarkExecutionOutcome {
        switch self {
        case .user: return .userCancelled
        case .lifecycle: return .lifecycleCancelled
        case .transport: return .transportAborted
        }
    }
}

nonisolated enum RendererBenchmarkCleanupOutcome: String, Codable, Sendable {
    case notRequired = "not_required"
    case restoredCurrent = "restored_current"
    case failed
}

nonisolated struct RendererBenchmarkGateFailure: Codable, Equatable, Sendable {
    let runId: String
    let profile: String
    let repeatNumber: Int
    let soak: Bool
    let rawFailure: String
    let observed: UInt64?
    let limit: UInt64?
    let unit: String?

    var displayText: String {
        let location = "\(profile.capitalized) repeat \(repeatNumber)" +
            (soak ? " (soak)" : "")
        guard let observed, let limit else {
            // Unknown/new gates remain visible, not silently discarded.
            return "\(location): \(rawFailure)"
        }
        let name = rawFailure.split(separator: ":", maxSplits: 1)
            .first.map(String.init) ?? rawFailure
        let suffix = unit.map { " \($0)" } ?? ""
        return "\(location): \(name) — observed \(observed)\(suffix), limit \(limit)\(suffix)"
    }
}

nonisolated struct RendererBenchmarkTerminalOutcome: Codable, Equatable, Sendable {
    let schema: Int
    let execution: RendererBenchmarkExecutionOutcome
    let cleanup: RendererBenchmarkCleanupOutcome
    let expectedComparisons: Int
    let completedComparisons: Int
    let passedComparisons: Int
    let soakCompleted: Bool
    let soakPassed: Bool
    let failures: [RendererBenchmarkGateFailure]
    let interruptionReason: String?

    var automatedPassed: Bool {
        execution == .completed && expectedComparisons > 0 &&
            completedComparisons == expectedComparisons &&
            passedComparisons == expectedComparisons &&
            soakCompleted && soakPassed && failures.isEmpty &&
            cleanup == .restoredCurrent
    }

    var status: String {
        let primary: String
        switch execution {
        case .completed:
            primary = automatedPassed ? "Completed — automated gates passed" :
                "Completed — automated gates failed"
        case .userCancelled: primary = "Cancelled by user"
        case .lifecycleCancelled: primary = "Cancelled by lifecycle change"
        case .transportAborted: primary = "Transport aborted"
        case .executionAborted: primary = "Execution aborted"
        }
        return primary + (cleanup == .failed ? " — Current restoration failed" : "")
    }

    var details: String {
        var lines = [
            "Comparisons: \(completedComparisons)/\(expectedComparisons) completed; \(passedComparisons) passed.",
            soakCompleted ? "Soak: \(soakPassed ? "passed" : "failed")." : "Soak: not completed.",
        ]
        lines += failures.map(\.displayText)
        if let interruptionReason { lines.append(interruptionReason) }
        switch cleanup {
        case .notRequired: lines.append("Current restoration was not required.")
        case .restoredCurrent: lines.append("Current profile restored.")
        case .failed: lines.append("Current-profile restoration was not confirmed.")
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated enum RendererBenchmarkObservation {
    /// Same firmware clock domain, including the millis() rollover. An age
    /// outside the forward half-range is ambiguous; do not fabricate a value.
    static func markerAgeMs(timestampMs: UInt32, receivedAtMs: UInt32,
                            valid: Bool) -> UInt64? {
        guard valid else { return nil }
        let delta = timestampMs &- receivedAtMs
        return delta < 0x8000_0000 ? UInt64(delta) : nil
    }
}
