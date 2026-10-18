import Foundation

@main
enum CompanionValidatorCLI {
    static func main() async {
        do {
            let receipt = try JSONDecoder().decode(TopographyCompanionReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
            let store = TopographyCompanionStore(url: URL(fileURLWithPath: CommandLine.arguments[1]), receipt: receipt)
            let metadata = try await store.validate()
            guard try await store.tile(z: 0, x: 0, y: 0, scale: 1) == nil else { fatalError("out-of-domain tile") }
            for z in [7, 8, 17, 22] {
                for scale in [1, 2] {
                    // The fixture has a contour through world (2000, 2000).
                    let count = Double(1 << z)
                    let x = Int((0.5 + 2000 / 40_075_016.68557849) * count)
                    let y = Int((0.5 - 2000 / 40_075_016.68557849) * count)
                    guard let first = try await store.displayTile(z: z, x: x, y: y, scale: scale),
                          let cached = try await store.displayTile(z: z, x: x, y: y, scale: scale),
                          first == cached else { fatalError("overview missing or cache mismatch") }
                    // A cached display overview must never expand the signed
                    // native tile domain or alter validation semantics.
                    guard try await store.tile(z: z, x: x, y: y, scale: scale) == nil else {
                        fatalError("display tile leaked into signed native reads")
                    }
                    await store.purgeCache()
                    guard try await store.displayTile(z: z, x: x, y: y, scale: scale) == first else {
                        fatalError("overview changed after cache purge")
                    }
                }
            }
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
                _ = try await store.displayTile(z: 7, x: 64, y: 63, scale: 1)
                fatalError("closed store returned an overview")
            } catch TopographyCompanionError.closed { }
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
