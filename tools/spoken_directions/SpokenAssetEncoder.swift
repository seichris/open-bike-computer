import Foundation

/// Slice-0 candidate only. Not a negotiated BLE codec or a production pack.
enum SpokenAssetEncoder {
    static let sampleRate = 16_000
    static let framesPerBlock = 160
    static let maximumFrames = sampleRate * 8
    static let headerBytes = 16

    enum Failure: Error { case empty, tooLong, invalidPCM }

    // IMA step/index algorithm; the BSA0 container is explicitly specified in
    // docs/spoken-directions-codec-prototype.md, not WAV IMA or RTP DVI4.
    static let steps = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
        34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118,
        130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371,
        408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166,
        1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
        3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845,
        8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500,
        20350, 22385, 24623, 27086, 29794, 32767
    ]
    static let indexDelta = [-1, -1, -1, -1, 2, 4, 6, 8]

    static func encode(_ samples: [Int16]) throws -> Data {
        guard !samples.isEmpty else { throw Failure.empty }
        guard samples.count <= maximumFrames else { throw Failure.tooLong }
        var output = Data([0x42, 0x53, 0x41, 0x30, 1, 1, 1, 0]) // BSA0
        appendLE(UInt32(sampleRate), to: &output)
        appendLE(UInt32(samples.count), to: &output)
        for start in stride(from: 0, to: samples.count, by: framesPerBlock) {
            let block = samples[start..<min(start + framesPerBlock, samples.count)]
            var predictor = Int(block.first!)
            let initialDifference = block.count > 1
                ? abs(Int(block[block.startIndex + 1]) - predictor) : 0
            var index = steps.firstIndex(where: { $0 >= initialDifference }) ?? 88
            appendLE(UInt16(bitPattern: Int16(predictor)), to: &output)
            output.append(UInt8(index))
            output.append(0)
            appendLE(UInt16(block.count), to: &output)
            appendLE(UInt16(block.count / 2), to: &output)
            var packed: UInt8 = 0
            for (position, sample) in block.dropFirst().enumerated() {
                let step = steps[index]
                var difference = Int(sample) - predictor
                var code = difference < 0 ? 8 : 0
                difference = abs(difference)
                var delta = step >> 3
                for (bit, weight) in [(4, step), (2, step >> 1), (1, step >> 2)] {
                    if difference >= weight {
                        code |= bit
                        difference -= weight
                        delta += weight
                    }
                }
                predictor = min(32767, max(-32768,
                    predictor + (code & 8 == 0 ? delta : -delta)))
                index = min(88, max(0, index + indexDelta[code & 7]))
                if position.isMultiple(of: 2) {
                    packed = UInt8(code)
                } else {
                    output.append(packed | UInt8(code << 4))
                }
            }
            if block.count.isMultiple(of: 2) { output.append(packed) }
        }
        return output
    }

    static func pcm16LE(_ data: Data) throws -> [Int16] {
        guard !data.isEmpty, data.count.isMultiple(of: 2) else {
            throw Failure.invalidPCM
        }
        guard data.count <= maximumFrames * 2 else { throw Failure.tooLong }
        let bytes = Array(data)
        return stride(from: 0, to: bytes.count, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
    }

    static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        for shift in stride(from: 0, to: T.bitWidth, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
