import SwiftUI
import UIKit

struct RideStatsDevicePreview: View {
    let layout: RideStatsLayout
    let firmwareTarget: String

    private struct Assets {
        let spec: RideStatsPreviewSpec
        let atlas: CGImage

        static let bundled: Assets? = {
            guard let data = NSDataAsset(name: "RideStatsPreview")?.data,
                  let spec = try? JSONDecoder().decode(RideStatsPreviewSpec.self, from: data),
                  let atlas = UIImage(named: "RideStatsPreviewAtlas")?.cgImage else {
                return nil
            }
            return Assets(spec: spec, atlas: atlas)
        }()
    }

    var body: some View {
        let widgets = layout.slots.map(\.rawValue)
        if let assets = Assets.bundled,
           let board = assets.spec.board(firmwareTarget: firmwareTarget, widgets: widgets) {
            Canvas { context, size in
                var drawing = context
                drawing.scaleBy(
                    x: size.width / CGFloat(board.width),
                    y: size.height / CGFloat(board.height)
                )
                let bounds = CGRect(x: 0, y: 0, width: CGFloat(board.width), height: CGFloat(board.height))
                let mask = board.round ? Path(ellipseIn: bounds) : Path(bounds)
                drawing.clip(to: mask)
                drawing.fill(mask, with: .color(.black))
                for tile in board.tiles(for: widgets) {
                    guard let key = tile.sprite,
                          let source = assets.spec.sprites[key],
                          let crop = rectangle(source),
                          let destination = rectangle(tile.bounds),
                          let image = assets.atlas.cropping(to: crop) else { continue }
                    drawing.draw(
                        Image(decorative: image, scale: 1).interpolation(.high),
                        in: destination
                    )
                }
                drawing.stroke(mask, with: .color(.gray.opacity(0.5)), lineWidth: 2)
            }
            .aspectRatio(CGFloat(board.width) / CGFloat(board.height), contentMode: .fit)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(board.round ? "Round 1.75-inch" : "2.06-inch") Ride Stats preview")
            .accessibilityValue(layout.slots.map(\.title).joined(separator: ", "))
            .accessibilityIdentifier("ride-stats-device-preview")
        } else {
            Text("Preview unavailable")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rectangle(_ values: [Int]) -> CGRect? {
        guard values.count == 4, values[2] > 0, values[3] > 0 else { return nil }
        return CGRect(x: CGFloat(values[0]), y: CGFloat(values[1]),
                      width: CGFloat(values[2]), height: CGFloat(values[3]))
    }
}
