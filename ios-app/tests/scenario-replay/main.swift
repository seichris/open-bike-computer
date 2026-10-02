import Foundation

struct Scenario: Decodable {
    let schema: Int
    let id: String
    let module: String
    let maxCount: Int
    let steps: [Step]
}
struct Step: Decodable {
    let action: String
    let label: String?
    let writeClass: String?
    let key: String?
    let milliseconds: Int?
    let canSend: Bool?
    let depth: Int?
    let oldestAgeMs: Int?
    let coalesced: Int?
    let cleared: Int?
    let delivered: [String]?
    let accepted: Bool?
}
func replay(_ path: String) throws {
    let scenario = try JSONDecoder().decode(Scenario.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard scenario.schema == 1, scenario.module == "navigation-write-queue",
          (1...64).contains(scenario.maxCount), (1...1000).contains(scenario.steps.count) else {
        throw NSError(domain: "scenario", code: 1)
    }
    var now: TimeInterval = 0
    var queue = NavigationWriteQueue(maxCount: scenario.maxCount, now: { now })
    var delivered: [String] = []
    for (index, step) in scenario.steps.enumerated() {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "\(scenario.id) step \(index): \(message)", code: 1) }
        }
        switch step.action {
        case "enqueue":
            guard let label = step.label, let name = step.writeClass,
                  let kind = NavigationWriteClass(rawValue: name) else { throw NSError(domain: "enqueue", code: index) }
            var dropped = false
            let write = NavigationWrite(data: Data(label.utf8), label: label, onDrop: { dropped = true }, writeClass: kind, coalescingKey: step.key)
            let accepted: Bool
            if step.key == nil { _ = queue.enqueue(write); accepted = !dropped }
            else { accepted = queue.enqueueCoalescing(write, prioritized: false) }
            try expect(accepted == (step.accepted ?? true), "unexpected acceptance")
        case "advance":
            guard let ms = step.milliseconds, (0...86400000).contains(ms) else { throw NSError(domain: "clock", code: index) }
            now += Double(ms) / 1000
        case "flush":
            guard let available = step.canSend else { throw NSError(domain: "transport", code: index) }
            queue.flush(canSend: { () -> Bool in available }, write: { delivered.append($0.label) })
        case "disconnect": queue.removeAll()
        case "expect":
            let metrics = queue.cumulativeMetrics
            if let depth = step.depth { try expect(queue.count == depth, "depth \(queue.count) != \(depth)") }
            if let age = step.oldestAgeMs { try expect(metrics.oldestPendingAgeMs == age, "pending age") }
            if let count = step.coalesced { try expect(metrics.coalescedFrames == count, "coalescing") }
            if let count = step.cleared { try expect(metrics.clearedFrames == count, "clear count") }
            if let labels = step.delivered { try expect(delivered == labels, "delivery \(delivered) != \(labels)") }
        default: throw NSError(domain: "unknown action", code: index)
        }
    }
    print("PASS: \(scenario.id) (\(scenario.steps.count) steps)")
}
do {
    for path in CommandLine.arguments.dropFirst() { try replay(path) }
} catch {
    fputs("Scenario replay failed: \(error)\n", stderr)
    exit(1)
}
