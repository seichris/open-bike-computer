import Foundation

extension Data {
    // Offsets are relative to startIndex, including for a non-zero-based slice.
    // Codecs must validate untrusted lengths before calling these primitives.
    nonisolated private func wireIndex(_ offset: Int, width: Int) -> Index {
        precondition(offset >= 0 && count >= width && offset <= count - width,
                     "wire field is outside the validated buffer")
        return startIndex + offset
    }

    nonisolated func wireUInt16LE(at offset: Int) -> UInt16 {
        let i = wireIndex(offset, width: 2)
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    nonisolated func wireUInt32LE(at offset: Int) -> UInt32 {
        let i = wireIndex(offset, width: 4)
        return UInt32(self[i]) | (UInt32(self[i + 1]) << 8) |
            (UInt32(self[i + 2]) << 16) | (UInt32(self[i + 3]) << 24)
    }

    nonisolated mutating func writeWireUInt16LE(_ value: UInt16, at offset: Int) {
        let i = wireIndex(offset, width: 2)
        self[i] = UInt8(truncatingIfNeeded: value)
        self[i + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    nonisolated mutating func writeWireUInt32LE(_ value: UInt32, at offset: Int) {
        let i = wireIndex(offset, width: 4)
        for byte in 0..<4 { self[i + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }

    nonisolated mutating func appendWireUInt16LE(_ value: UInt16) {
        let offset = count
        append(contentsOf: [0, 0])
        writeWireUInt16LE(value, at: offset)
    }

    nonisolated mutating func appendWireUInt32LE(_ value: UInt32) {
        let offset = count
        append(contentsOf: [0, 0, 0, 0])
        writeWireUInt32LE(value, at: offset)
    }
}
