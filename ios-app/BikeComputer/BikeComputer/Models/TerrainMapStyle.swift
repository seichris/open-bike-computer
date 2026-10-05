import Foundation

// Terrain modes are presets of independent Map instances, not new screen IDs.
enum TerrainMapStyle: UInt32, CaseIterable, Identifiable {
  case none = 0
  case hillshade = 0x4000
  case elevationTint = 0xc000
  case slope = 0x10000
  case terrain3D = 0x20000
  var id: UInt32 { rawValue }
  var title: String {
    switch self {
    case .none: return "Plain Map"
    case .hillshade: return "Hillshade"
    case .elevationTint: return "Elevation Tint"
    case .slope: return "Slope"
    case .terrain3D: return "3D Terrain"
    }
  }
}
