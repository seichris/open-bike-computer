import Foundation
final class MemoryDefaults {
    var value: [String: Any] = [:]
    var writes = 0
    func set(_ value: [String: Any], forKey: String) { self.value = value; writes += 1 }
}
enum UserDefaults { static let standard = MemoryDefaults() }
enum State: String { case paused, running }
enum Connection: String { case attached }
enum Origin: String { case restored }
struct Presentation { var sessionState: State = .paused; var connectionState: Connection = .attached }
final class Store { var presentation = Presentation(); var currentEnvelope: Int? = 1 }
final class Probe {
    var debugCheckpointFields: NSDictionary?
    var debugAttachmentCount = 1
    var debugAttachmentOrigin: Origin = .restored
    var store = Store()
    var mirroredSessionStorage: Int? = 1
    func now() -> Date { Date() }
    // CHECKPOINT_METHOD
}
let probe = Probe()
probe.recordMirrorDebugCheckpoint(reason: "nativeState")
probe.store.presentation.sessionState = .running
probe.recordMirrorDebugCheckpoint(reason: "nativeState")
precondition(UserDefaults.standard.value["state"] as? String == "running")
probe.recordMirrorDebugCheckpoint(reason: "nativeState")
precondition(UserDefaults.standard.writes == 2)
probe.store.currentEnvelope = nil
probe.recordMirrorDebugCheckpoint(reason: "nativeState")
precondition(UserDefaults.standard.value["hasCredentials"] as? Bool == false && UserDefaults.standard.writes == 3)
print("Repeated checkpoint reasons update changed fields and deduplicate unchanged fields")
