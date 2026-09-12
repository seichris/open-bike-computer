import Foundation

@main
enum EncoderTests {
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
    static func main() throws {
        let golden = try SpokenAssetEncoder.encode([0, 7, -7])
        require(Array(golden) == [
            0x42,0x53,0x41,0x30,1,1,1,0,0x80,0x3e,0,0,3,0,0,0,
            0,0,0,0,3,0,1,0,0xe4
        ], "hand-derived golden differs")
        let silence = try SpokenAssetEncoder.encode([0, 0])
        require(Array(silence.suffix(9)) == [0,0,0,0,2,0,1,0,0], "padding")
        let extreme = try SpokenAssetEncoder.encode([32767, -32768])
        require(Array(extreme.suffix(9)) == [255,127,88,0,2,0,1,0,15], "saturated initial index")
        for size in [1,2,3,159,160,161,319,320,321,48_000,128_000] {
            let input = (0..<size).map { Int16(($0 % 200) * 200 - 20_000) }
            let a = try SpokenAssetEncoder.encode(input)
            let b = try SpokenAssetEncoder.encode(input)
            require(a == b, "encoding must be deterministic")
            let blocks = (size + 159) / 160
            let last = size % 160
            let payload = (size / 160) * 80 + last / 2
            require(a.count == 16 + 8 * blocks + payload, "exact byte accounting")
        }
        do { _ = try SpokenAssetEncoder.encode([]); fatalError("empty accepted") }
        catch SpokenAssetEncoder.Failure.empty {}
        do {
            _ = try SpokenAssetEncoder.encode(Array(repeating: 0, count: 128_001))
            fatalError("oversize accepted")
        } catch SpokenAssetEncoder.Failure.tooLong {}
        do { _ = try SpokenAssetEncoder.pcm16LE(Data([1])); fatalError("odd PCM accepted") }
        catch SpokenAssetEncoder.Failure.invalidPCM {}
        let pcm = try SpokenAssetEncoder.pcm16LE(Data([0,128,255,127,255,255]))
        require(pcm == [-32768,32767,-1], "signed little endian")
        print("Swift candidate encoder: golden, deterministic boundaries, limits, PCM passed")
    }
}
