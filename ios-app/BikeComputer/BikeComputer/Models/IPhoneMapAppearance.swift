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

struct IPhoneMapAppearance: Equatable {
    static let baseStyleDefaultsKey = "iphoneMapAppearance.baseStyle.v1"
    static let realisticElevationDefaultsKey =
        "iphoneMapAppearance.realisticElevation.v1"
    static let defaultValue = Self(
        baseStyle: .standard,
        usesRealisticElevation: false
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
