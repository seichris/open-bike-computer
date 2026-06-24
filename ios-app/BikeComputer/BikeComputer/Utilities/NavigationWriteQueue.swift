import Foundation

struct NavigationWriteQueue {
    let maxCount: Int
    private var pendingWrites: [Data] = []

    var count: Int {
        pendingWrites.count
    }

    init(maxCount: Int) {
        self.maxCount = max(1, maxCount)
    }

    @discardableResult
    mutating func enqueue(_ data: Data) -> Bool {
        pendingWrites.append(data)
        let overflowCount = pendingWrites.count - maxCount
        guard overflowCount > 0 else { return false }

        pendingWrites.removeFirst(overflowCount)
        return true
    }

    mutating func removeAll() {
        pendingWrites.removeAll()
    }

    mutating func flush(canSend: () -> Bool, write: (Data) -> Void) {
        while !pendingWrites.isEmpty && canSend() {
            write(pendingWrites.removeFirst())
        }
    }
}
