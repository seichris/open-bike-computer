import Foundation
import MapKit

enum BikeLanesTileSource {
    nonisolated static let infoDictionaryHostKey = "BicinoBikeLanesTileHost"
    nonisolated static let infoDictionaryPathKey = "BicinoBikeLanesTilePath"

    /// The overlay is configured in `BikeLanesTileOverlay`: tiles z12 to z18,
    /// shown from `BikeLanesZoomRange.minimumVisibleZoom`, cached in memory
    /// and on disk.
    static func make(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> BikeLanesTileOverlay? {
#if DEBUG && targetEnvironment(simulator)
        if let local = CyclOSMLiteTileOverlay.openFixture() { return local }
#endif
        guard let template = urlTemplate(
            host: infoDictionary[infoDictionaryHostKey] as? String,
            path: infoDictionary[infoDictionaryPathKey] as? String
        ) else { return nil }
        return BikeLanesTileOverlay(urlTemplate: template)
    }

    /// The HTTPS XYZ template for the configured tile service, or nil when the
    /// build leaves it unset or invalid. The host and path are separate build
    /// settings because an xcconfig value ends at "//", which would cut a full
    /// URL down to "https:".
    nonisolated static func urlTemplate(host rawHost: String?, path rawPath: String?) -> String? {
        let host = (rawHost ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = (rawPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let label = "[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
        let placeholders = ["{z}", "{x}", "{y}"]
        guard host.range(of: "^(?:\(label)\\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$",
                         options: .regularExpression) != nil,
              path.hasPrefix("/"), !path.contains("//"),
              placeholders.allSatisfy({ path.contains($0) }) else { return nil }
        let template = "https://\(host)\(path)"
        let sample = (placeholders + ["{scale}"]).reduce(template) { url, placeholder in
            url.replacingOccurrences(of: placeholder, with: "0")
        }
        guard let url = URL(string: sample), url.scheme == "https", url.host == host,
              url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil else { return nil }
        return template
    }
}

#if DEBUG && targetEnvironment(simulator)
/// Reads a small, locally supplied set of CyclOSM Lite XYZ tiles for Simulator QA.
nonisolated final class CyclOSMLiteTileOverlay: BikeLanesTileOverlay, @unchecked Sendable {
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
