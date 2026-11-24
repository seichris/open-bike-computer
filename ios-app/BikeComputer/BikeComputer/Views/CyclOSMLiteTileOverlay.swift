import Foundation
import MapKit

enum BikeLanesTileSource {
    static func make(bundle: Bundle = .main) -> MKTileOverlay? {
#if DEBUG && targetEnvironment(simulator)
        if let local = CyclOSMLiteTileOverlay.openFixture() { return configure(local) }
#endif
        guard let template = bundle.object(forInfoDictionaryKey: "BicinoBikeLanesTileURLTemplate") as? String,
              let url = tileURL(from: template), url.scheme == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return configure(MKTileOverlay(urlTemplate: template))
    }

    private static func tileURL(from template: String) -> URL? {
        let placeholders = ["{z}", "{x}", "{y}"]
        guard placeholders.allSatisfy({ template.contains($0) }) else { return nil }
        let sample = placeholders.reduce(template) { url, placeholder in
            url.replacingOccurrences(of: placeholder, with: "0")
        }
        return URL(string: sample)
    }

    private static func configure(_ overlay: MKTileOverlay) -> MKTileOverlay {
        overlay.canReplaceMapContent = false
        overlay.minimumZ = 13
        overlay.maximumZ = 18
        return overlay
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Reads a small, locally supplied set of CyclOSM Lite XYZ tiles for Simulator QA.
nonisolated final class CyclOSMLiteTileOverlay: MKTileOverlay, @unchecked Sendable {
    private let directory: URL

    private init(directory: URL) {
        self.directory = directory
        super.init(urlTemplate: nil)
    }

    static func openFixture() -> CyclOSMLiteTileOverlay? {
        let directory = URL.documentsDirectory.appending(path: "CyclOSMLiteTeal", directoryHint: .isDirectory)
        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return nil
        }
        return CyclOSMLiteTileOverlay(directory: directory)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let relativePath = "\(path.z)/\(path.x)/\(path.y).png"
        let data = try? Data(contentsOf: directory.appending(path: relativePath))
        if ProcessInfo.processInfo.arguments.contains("--bike-lanes-tile-diagnostics") {
            print("BIKE_LANES_TILE \(relativePath) \(data == nil ? "missing" : "loaded")")
        }
        result(data, nil)
    }
}

#endif
