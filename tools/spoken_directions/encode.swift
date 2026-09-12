import Foundation

@main
enum EncoderCLI {
    static func main() {
        do { try encode() }
        catch {
            FileHandle.standardError.write(Data("Input/output rejected; use encode INPUT.s16le OUTPUT.bsa0\n".utf8))
            exit(1)
        }
    }
    static func encode() throws {
        guard CommandLine.arguments.count == 3 else {
            throw CLIError.usage
        }
        // One byte beyond the limit distinguishes oversized input without
        // mapping or allocating an arbitrarily large caller-supplied file.
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { try? input.close() }
        var data = Data()
        let limit = SpokenAssetEncoder.maximumFrames * 2
        while data.count <= limit {
            let part = try input.read(upToCount: min(4096, limit + 1 - data.count)) ?? Data()
            if part.isEmpty { break }
            data.append(part)
        }
        let samples = try SpokenAssetEncoder.pcm16LE(data)
        let encoded = try SpokenAssetEncoder.encode(samples)
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        // Never overwrite a recording or a previous measurement.
        try encoded.write(to: destination, options: .withoutOverwriting)
        print("frames=\(samples.count) pcm_mono_bytes=\(data.count) candidate_bytes=\(encoded.count)")
    }
    enum CLIError: Error { case usage } // encode INPUT.s16le OUTPUT.bsa0
}
