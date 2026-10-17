import Foundation

@main
enum CompanionValidatorCLI {
    static func main() async {
        do {
            let receipt = try JSONDecoder().decode(TopographyCompanionReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let store = TopographyCompanionStore(url: URL(fileURLWithPath: CommandLine.arguments[1]), receipt: receipt)
            let metadata = try await store.validate()
            guard try await store.tile(z: 0, x: 0, y: 0, scale: 1) == nil else { fatalError("out-of-domain tile") }
            if CommandLine.arguments.count > 3 {
                let labels = try await store.labels(west: 0, south: 0, east: 4096, north: 4096)
                precondition(labels.count == 512)
                for east in [false, true] {
                    for north in [false, true] {
                        precondition(labels.filter { ($0.x >= 2048) == east && ($0.y >= 2048) == north }.count > 80,
                                     "dense labels must cover all four quadrants")
                    }
                }
            }
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
