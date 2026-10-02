import Foundation

@main
enum ContourValidatorCLI {
    static func main() {
        while let line = readLine() {
            let values = Array(line.utf8)
            var bytes = Data()
            for index in stride(from: 0, to: values.count, by: 2) {
                guard index + 1 < values.count,
                      let value = UInt8(String(bytes: values[index...index + 1], encoding: .utf8)!, radix: 16) else { return }
                bytes.append(value)
            }
            do {
                _ = try TopographyContourSection.validate(bytes)
                print("1")
            } catch { print("0") }
        }
    }
}
