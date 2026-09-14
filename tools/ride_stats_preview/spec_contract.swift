import Foundation

@main
struct PreviewSpecContract {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let spec = try JSONDecoder().decode(RideStatsPreviewSpec.self, from: data)
        precondition(spec.schema == 1 && spec.boards.count == 8)
        let defaults: [UInt8] = [1, 2, 3, 4, 5, 15, 16]
        let round = spec.board(firmwareTarget: "WAVESHARE_AMOLED_175", widgets: defaults)!
        let rectangular = spec.board(firmwareTarget: "WAVESHARE_AMOLED_206", widgets: defaults)!
        precondition(round.round && round.width == 466 && round.height == 466)
        precondition(!rectangular.round && rectangular.width == 410 && rectangular.height == 502)
        precondition(spec.board(firmwareTarget: "", widgets: defaults)?.round == true)
        precondition(round.tiles(for: []).isEmpty)
        precondition(round.tiles(for: defaults).last?.fonts[5] == 38)
        precondition(round.tiles(for: defaults).last?.fonts[6] == 38)
        for target in ["WAVESHARE_AMOLED_175", "WAVESHARE_AMOLED_206"] {
            for widget: UInt8 in 0...16 {
                let widgets = Array(repeating: widget, count: 7)
                let board = spec.board(firmwareTarget: target, widgets: widgets)!
                let tiles = board.tiles(for: widgets)
                precondition(!tiles.isEmpty)
                for tile in tiles where tile.sprite != nil {
                    precondition(tile.bounds.count == 4 && tile.fonts.count == 7)
                    precondition(spec.sprites[tile.sprite!] != nil)
                }
            }
            for row in 0..<3 {
                var widgets: [UInt8] = Array(repeating: 0, count: 7)
                widgets[row * 2 + 1] = 6 // Elapsed time.
                widgets[row * 2 + 2] = 7 // Altitude.
                let board = spec.board(firmwareTarget: target, widgets: widgets)!
                let pair = board.pairs["\(row):6:7"]!
                precondition(pair.fonts[row * 2 + 1] == pair.fonts[row * 2 + 2])
                precondition(board.tiles(for: widgets).contains { $0.sprite == pair.sprite })
            }
        }
        // Smart fields reflect the selected example sensors across the whole page.
        var withPower = defaults
        withPower[0] = 9
        let smartWithoutPower = round.pairs["2:15:16"]!.sprite
        let power = spec.board(firmwareTarget: "WAVESHARE_AMOLED_175", widgets: withPower)!
        precondition(power.pairs["2:15:16"]!.sprite != smartWithoutPower)
        print("Ride Stats Swift preview composition passed")
    }
}
