import Foundation
import MapKit

enum IPhoneMapBaseStyle: String, CaseIterable, Identifiable {
    case standard
    case satellite
    case hybrid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard:
            return "Standard"
        case .satellite:
            return "Satellite"
        case .hybrid:
            return "Hybrid"
        }
    }

    var systemImage: String {
        switch self {
        case .standard:
            return "map"
        case .satellite:
            return "globe.americas.fill"
        case .hybrid:
            return "map.fill"
        }
    }

    static func resolved(persistedRawValue: String?) -> Self {
        persistedRawValue.flatMap(Self.init(rawValue:)) ?? .standard
    }
}

/// MapKit shows flat ground while an overlay it did not create is on the map,
/// and returns to realistic ground when the last one is removed; MapKit
/// Directions polylines follow the terrain instead (WWDC22, "What's new in
/// MapKit"). The inputs mirror the overlays `MapViewContainer` installs, so the
/// 3D Terrain row can show what the rider sees without changing the saved
/// preference. Calculated routes and alternatives are Directions polylines.
enum RealisticTerrainOverlayPolicy {
    nonisolated static func isPaused(
        showsBikeLanes: Bool,
        showsContours: Bool,
        showsSavedRoutePreview: Bool,
        isNavigating: Bool,
        hasCalculatedRoute: Bool,
        hasOfflineRoute: Bool,
        hasDetour: Bool
    ) -> Bool {
        showsBikeLanes || showsContours || showsSavedRoutePreview ||
            // MapViewContainer draws these two only while navigating, and the
            // offline line only without a calculated route.
            (isNavigating && !hasCalculatedRoute && hasOfflineRoute) ||
            (isNavigating && hasDetour)
    }

    nonisolated static func displayedValue(preference: Bool, isPaused: Bool) -> Bool {
        preference && !isPaused
    }

    /// The paused row is disabled; a late write must not replace the preference.
    nonisolated static func preference(
        afterRequesting requested: Bool,
        current: Bool,
        isPaused: Bool
    ) -> Bool {
        isPaused ? current : requested
    }
}

struct IPhoneMapAppearance: Equatable {
    static let baseStyleDefaultsKey = "iphoneMapAppearance.baseStyle.v1"
    static let realisticElevationDefaultsKey =
        "iphoneMapAppearance.realisticElevation.v1"
    static let defaultValue = Self(
        baseStyle: .standard,
        usesRealisticElevation: true
    )

    let baseStyle: IPhoneMapBaseStyle
    let usesRealisticElevation: Bool

    init(
        baseStyle: IPhoneMapBaseStyle,
        usesRealisticElevation: Bool
    ) {
        self.baseStyle = baseStyle
        self.usesRealisticElevation = usesRealisticElevation
    }

    init(
        persistedBaseStyleRawValue: String?,
        usesRealisticElevation: Bool
    ) {
        self.init(
            baseStyle: .resolved(
                persistedRawValue: persistedBaseStyleRawValue
            ),
            usesRealisticElevation: usesRealisticElevation
        )
    }

    @MainActor
    func makeConfiguration() -> MKMapConfiguration {
        let elevationStyle: MKMapConfiguration.ElevationStyle =
            usesRealisticElevation ? .realistic : .flat

        switch baseStyle {
        case .standard:
            return MKStandardMapConfiguration(
                elevationStyle: elevationStyle
            )
        case .satellite:
            return MKImageryMapConfiguration(
                elevationStyle: elevationStyle
            )
        case .hybrid:
            return MKHybridMapConfiguration(
                elevationStyle: elevationStyle
            )
        }
    }
}
