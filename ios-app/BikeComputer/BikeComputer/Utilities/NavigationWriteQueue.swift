import Foundation

struct NavigationWrite {
    let data: Data
    let label: String
    let transportWrite: ((Data) -> Void)?
    let onWrite: (() -> Void)?
    let onDrop: (() -> Void)?

    init(
        data: Data,
        label: String,
        transportWrite: ((Data) -> Void)? = nil,
        onWrite: (() -> Void)? = nil,
        onDrop: (() -> Void)? = nil
    ) {
        self.data = data
        self.label = label
        self.transportWrite = transportWrite
        self.onWrite = onWrite
        self.onDrop = onDrop
    }

    func perform(using fallbackWrite: (Data) -> Void) {
        if let transportWrite {
            transportWrite(data)
        } else {
            fallbackWrite(data)
        }
        onWrite?()
    }
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

        let droppedWrites = pendingWrites.prefix(overflowCount)
        pendingWrites.removeFirst(overflowCount)
        droppedWrites.forEach { $0.onDrop?() }
        return true
    }

    mutating func removeAll() {
        pendingWrites.removeAll()
    }

    mutating func flush(
        canSend: () -> Bool,
        maxWrites: Int = .max,
        write: (NavigationWrite) -> Void
    ) {
        var writesRemaining = max(0, maxWrites)
        while writesRemaining > 0 && !pendingWrites.isEmpty && canSend() {
            write(pendingWrites.removeFirst())
            writesRemaining -= 1
        }
    }
}
