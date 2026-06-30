import Foundation

struct NavigationWrite {
    let data: Data
    let label: String
}

struct NavigationWriteQueue {
    let maxCount: Int
    private var pendingWrites: [NavigationWrite] = []

    var count: Int {
        pendingWrites.count
    }

    init(maxCount: Int) {
        self.maxCount = max(1, maxCount)
    }

    @discardableResult
    mutating func enqueue(_ write: NavigationWrite) -> Bool {
        pendingWrites.append(write)
        let overflowCount = pendingWrites.count - maxCount
        guard overflowCount > 0 else { return false }

        pendingWrites.removeFirst(overflowCount)
        return true
    }

    mutating func removeAll() {
        pendingWrites.removeAll()
    }

    mutating func flush(canSend: () -> Bool, write: (NavigationWrite) -> Void) {
        while !pendingWrites.isEmpty && canSend() {
            write(pendingWrites.removeFirst())
        }
    }
}
