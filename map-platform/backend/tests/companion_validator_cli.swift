import Foundation

@main
enum CompanionValidatorCLI {
    static func main() async {
        do {
            let receipt = try JSONDecoder().decode(TopographyCompanionReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let store = TopographyCompanionStore(url: URL(fileURLWithPath: CommandLine.arguments[1]), receipt: receipt)
            let metadata = try await store.validate()
            guard try await store.tile(z: 0, x: 0, y: 0, scale: 1) == nil else { fatalError("out-of-domain tile") }
            await store.close()
            do {
                _ = try await store.tile(z: 9, x: 256, y: 256, scale: 1)
                fatalError("closed store returned a tile")
            } catch TopographyCompanionError.closed { }
            print("ok \(metadata.tileCount)")
        } catch {
            print("invalid")
        }
    }
}
