import Foundation

/// One combined size for friend portraits and their numbers, shared by the
/// iPhone map and every bike-computer map screen (BLE map setting 39).
nonisolated enum FriendMarkerScale: Int, CaseIterable, Identifiable, Sendable {
    case normal = 100
    case oneAndQuarter = 125
    case oneAndHalf = 150
    case double = 200
    case twoAndHalf = 250
    case triple = 300

    static let defaultsKey = "social.map.friendMarkerScale.v2"
    /// PR 610 stored separate Small/Medium/Large picture and number sizes.
    static let legacyPictureKey = "social.map.pictureSize.v1"
    static let legacyNumberKey = "social.map.numberSize.v1"

    var id: Int { rawValue }
    /// Multiplier of the normal marker geometry.
    var factor: Double { Double(rawValue) / 100 }

    var title: String {
        switch self {
        case .normal: "Normal (1×)"
        case .oneAndQuarter: "1.25×"
        case .oneAndHalf: "1.5×"
        case .double: "2×"
        case .twoAndHalf: "2.5×"
        case .triple: "3×"
        }
    }

    /// The nearest offered size for a stored or received percent.
    static func resolved(_ percent: Int) -> FriendMarkerScale {
        allCases.min { abs($0.rawValue - percent) < abs($1.rawValue - percent) } ?? .normal
    }

    /// Loads the shared preference, migrating the separate PR 610 sizes once.
    /// Small (0.8×) and Medium (1×) become Normal because smaller markers are no
    /// longer offered; Large (1.3×) on either control becomes 1.25×, the nearest
    /// offered size, so a rider who enlarged markers keeps them enlarged.
    static func load(from defaults: UserDefaults) -> FriendMarkerScale {
        if let stored = defaults.object(forKey: defaultsKey) as? Int {
            return resolved(stored)
        }
        let legacy = [legacyPictureKey, legacyNumberKey].compactMap(defaults.string(forKey:))
        let migrated: FriendMarkerScale = legacy.contains("large") ? .oneAndQuarter : .normal
        defaults.set(migrated.rawValue, forKey: defaultsKey)
        defaults.removeObject(forKey: legacyPictureKey)
        defaults.removeObject(forKey: legacyNumberKey)
        return migrated
    }
}
