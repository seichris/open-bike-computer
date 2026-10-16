import Foundation
// SHARED_TYPES
enum WatchBLEOutboundQueueV1 { static let maximumFrameBytes = 512 }
final class WatchProbe {
    let defaults: UserDefaults
    let pendingTransportDiagnosticsKey = "pending"
    let inFlightTransportDiagnosticsKey = "inflight"
    var session: Int? = nil
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func flushPendingTransportDiagnostics(using: Int) {}
    // WATCH_METHODS
}
enum Level { case info, warning }
enum Category { case ble }
final class Recorder {
    let processId = UUID()
    var captures: [UUID?] = []
    var records: [(String, [String: String])] = []
    func record(level: Level, category: Category, event: String, fields: [String: String], captureId: UUID? = nil) { records.append((event, fields)); captures.append(captureId) }
}
final class PhoneProbe {
    static let receivedTransportDiagnosticIDsDefaultsKey = "received"
    let defaults: UserDefaults
    let diagnosticsRecorder: Recorder? = Recorder()
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    // PHONE_METHOD
}
let suite = "bicino.host-watch-loss." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let watch = WatchProbe(defaults)
let attempt = UUID()
func event(_ sequence: UInt32) -> WatchBLETransportDiagnosticEventV1 {
    .init(attemptID: attempt, sequence: sequence, kind: .transportTransition,
        phase: "ready", reason: nil, connectionGeneration: 1, queueDepth: 0,
        queueHighWater: 0, queueBytes: nil, queueHighWaterBytes: nil,
        replacedGroups: 0, rejectedGroups: 0, uptimeMs: Int(sequence), latencyMs: nil)
}
for i in 1...66 { watch.recordTransportDiagnostic(event(UInt32(i))) }
let data = defaults.data(forKey: "pending")!
let batch = WatchBLETransportDiagnosticBatchV1.decode(data)!
precondition(batch.events.first!.sequence == 3 && batch.events.last!.sequence == 66 && batch.droppedEventCount == 2)
let phone = PhoneProbe(defaults)
precondition(phone.receiveTransportDiagnostics([WatchBLETransportDiagnosticBatchV1.userInfoPayloadKey: data]))
precondition(phone.diagnosticsRecorder!.records.contains { $0.0 == "watch_ble_diagnostics_loss" && $0.1["droppedCount"] == "2" })
let restarted = WatchProbe(UserDefaults(suiteName: suite)!)
restarted.recordTransportDiagnostic(event(67))
let reloaded = WatchBLETransportDiagnosticBatchV1.decode(defaults.data(forKey: "pending")!)!
precondition(reloaded.producerID == batch.producerID && reloaded.droppedEventCount == 3)
precondition(reloaded.events.first!.sequence == 4 && reloaded.events.last!.sequence == 67)
restarted.mergePendingTransportDiagnostics(data)
let retried = WatchBLETransportDiagnosticBatchV1.decode(defaults.data(forKey: "pending")!)!
precondition(retried.droppedEventCount! >= 3 && retried.producerID == batch.producerID)
print("Watch overflow survives batching, queued retry, preference reload and phone recorder import")

precondition(phone.diagnosticsRecorder!.records.filter { $0.0 != "watch_ble_diagnostics_loss" }.allSatisfy {
    $0.1["originCaptureAssociation"] == "unknown" && $0.1["timeBasis"] == "phone_receipt"
})
precondition(phone.diagnosticsRecorder!.captures.allSatisfy { $0 == phone.diagnosticsRecorder!.processId })
var timed = event(100)
timed.originUnixTimeMs = 1_800_000_000_123
timed.originProcessID = UUID()
let delayed = try WatchBLETransportDiagnosticBatchV1(events: [timed]).encoded()
precondition(phone.receiveTransportDiagnostics([WatchBLETransportDiagnosticBatchV1.userInfoPayloadKey: delayed]))
let recorded = phone.diagnosticsRecorder!.records.last!.1
precondition(recorded["originUnixTimeMs"] == "1800000000123")
precondition(recorded["originProcessId"] == timed.originProcessID!.uuidString.lowercased())
print("Delayed and legacy Watch events retain origin/receipt distinction without inheriting current ride")
