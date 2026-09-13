import Foundation

/// Allocation-bounded FMB v5 section-5 reader. The enclosing FMB directory,
/// section CRC and signed file digest must be verified by the stream reader.
nonisolated enum TopographyContourSection {
    struct Summary: Equatable, Sendable {
        let minorIntervalM: Int
        let indexIntervalM: Int
        let recordCount: Int
        let pointCount: Int
    }

    enum Invalid: Error { case section }

    static func validate(_ data: Data) throws -> Summary {
        guard (12...(12 + 4096 * 14 + 65536 * 4)).contains(data.count) else { throw Invalid.section }
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func i16(_ at: Int) -> Int { let value = u16(at); return value < 32768 ? value : value - 65536 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        let minor = u16(2), index = u16(4), count = u16(6), declared = u32(8)
        guard bytes[0] == 1, bytes[1] == 0,
              (minor == 20 && index == 100) || (minor == 50 && index == 250),
              count <= 4096, declared <= 65536 else { throw Invalid.section }
        var cursor = 12, total = 0
        var previousKey: [Int]?
        var previousPoints: [UInt8] = []
        for _ in 0..<count {
            try Task.checkCancellation()
            guard bytes.count - cursor >= 14 else { throw Invalid.section }
            let elevation = i16(cursor), flags = Int(bytes[cursor + 2]), points = u16(cursor + 4)
            let bounds = [i16(cursor + 6), i16(cursor + 8), i16(cursor + 10), i16(cursor + 12)]
            guard (-12000...10000).contains(elevation), elevation % minor == 0,
                  flags & ~7 == 0, (flags & 1 != 0) == (elevation % index == 0),
                  bytes[cursor + 3] == 0, (2...256).contains(points), points <= declared - total else {
                throw Invalid.section
            }
            cursor += 14
            guard bytes.count - cursor >= points * 4 else { throw Invalid.section }
            let encoded = Array(bytes[cursor..<cursor + points * 4])
            var x = 0, y = 0, minimumX = 4096, minimumY = 4096, maximumX = 0, maximumY = 0
            for number in 0..<points {
                let dx = i16(cursor), dy = i16(cursor + 2)
                cursor += 4
                if number > 0 {
                    guard dx != 0 || dy != 0, dx * dx + dy * dy <= 512 * 512 else { throw Invalid.section }
                }
                x += dx; y += dy
                guard (0...4096).contains(x), (0...4096).contains(y) else { throw Invalid.section }
                minimumX = min(minimumX, x); minimumY = min(minimumY, y)
                maximumX = max(maximumX, x); maximumY = max(maximumY, y)
            }
            guard bounds == [minimumX, minimumY, maximumX, maximumY] else { throw Invalid.section }
            let key = [elevation, flags] + bounds
            if let previousKey {
                guard previousKey.lexicographicallyPrecedes(key) ||
                        (previousKey == key && previousPoints.lexicographicallyPrecedes(encoded)) else { throw Invalid.section }
            }
            previousKey = key; previousPoints = encoded; total += points
        }
        guard cursor == bytes.count, total == declared else { throw Invalid.section }
        return Summary(minorIntervalM: minor, indexIntervalM: index, recordCount: count, pointCount: total)
    }
}
