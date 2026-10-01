import Foundation
import CoreFoundation

nonisolated struct DiagnosticsLiveTailV2: Sendable {
    let bootSequence: UInt32
    let requestedBoot: UInt32
    let requestedAfter: UInt32
    let nextSequence: UInt32
    let data: Data

    init?(data: Data) {
        guard data.count <= 8 * 768 + 1024,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == Set(["schema", "source", "bootSequence", "requestedBoot", "requestedAfter", "nextSequence", "oldestSequence", "newestSequence", "bootChanged", "gap", "more", "liveDropped", "durableSequence", "durableSequenceValid", "events"]),
              value["schema"] as? Int == 2, value["source"] as? String == "firmware",
              let events = value["events"] as? [[String: Any]], events.count <= 8 else { return nil }
        var numbers: [String: UInt32] = [:]
        for key in ["bootSequence", "requestedBoot", "requestedAfter", "nextSequence", "oldestSequence", "newestSequence", "liveDropped", "durableSequence"] {
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= Double(UInt32.max),
                  number.doubleValue.rounded(.down) == number.doubleValue else { return nil }
            numbers[key] = number.uint32Value
        }
        for key in ["bootChanged", "gap", "more", "durableSequenceValid"] {
            guard let item = value[key], CFGetTypeID(item as CFTypeRef) == CFBooleanGetTypeID() else { return nil }
        }
        guard let boot = numbers["bootSequence"], boot > 0 else { return nil }
        var previous: UInt32?
        for event in events {
            guard let sequence = event["sequence"] as? UInt32,
                  previous == nil || sequence > previous!,
                  event["schema"] as? Int == 1, event["source"] as? String == "firmware",
                  let level = event["level"] as? String, DiagnosticsContractV2.levels.contains(level),
                  let category = event["category"] as? String, DiagnosticsContractV2.domains.contains(category),
                  let name = event["event"] as? String, !name.isEmpty, name.utf8.count <= 64,
                  name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }),
                  let fields = event["fields"] as? [String: Any], fields.count <= 32,
                  fields["bootSequence"] as? UInt32 == boot,
                  Set(event.keys).isSubset(of: ["schema","source","sequence","level","category","event","wallTime","uptimeMs","captureId","fields"]),
                  fields.allSatisfy({ RideDiagnosticsFieldPolicy.isAllowed($0.key) && RideDiagnosticsFieldPolicy.isFirmwareFieldTypeValid(key: $0.key, value: $0.value) }) else { return nil }
            previous = sequence
        }
        guard previous == nil || previous == numbers["nextSequence"] else { return nil }
        self.bootSequence = boot; self.requestedBoot = numbers["requestedBoot"]!; self.requestedAfter = numbers["requestedAfter"]!
        self.nextSequence = numbers["nextSequence"]!; self.data = data
    }
}
