import Foundation
import MapKit

// MapView only needs the selection bounds shape in this focused Catalyst test.
struct OfflineMapBounds {
    let minLon: Double
    let minLat: Double
    let maxLon: Double
    let maxLat: Double
}

@MainActor
private final class RecordingMapAppearanceTarget:
    MapAppearanceConfigurationTarget {
    private(set) var assignmentCount = 0
    var preferredConfiguration: MKMapConfiguration {
        didSet { assignmentCount += 1 }
    }

    init() {
        preferredConfiguration = MKStandardMapConfiguration(
            elevationStyle: .flat
        )
    }
}

@MainActor
@main
struct MapAppearanceTests {
    static func main() {
        testDefaultAppearance()
        testPersistedBaseStyleRoundTrip()
        testUnknownPersistedStyleFallsBackToStandard()
        testConfigurationMapping()
        testAppearanceEquality()
        testIdempotentApplication()
        testMapPitchControlTargets()

        print("MapAppearanceTests passed")
    }

    private static func testDefaultAppearance() {
        precondition(
            IPhoneMapAppearance.defaultValue == IPhoneMapAppearance(
                baseStyle: .standard,
                usesRealisticElevation: false
            )
        )
    }

    private static func testPersistedBaseStyleRoundTrip() {
        let suiteName = "MapAppearanceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("unable to create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for style in IPhoneMapBaseStyle.allCases {
            defaults.set(
                style.rawValue,
                forKey: IPhoneMapAppearance.baseStyleDefaultsKey
            )
            let restored = IPhoneMapAppearance(
                persistedBaseStyleRawValue: defaults.string(
                    forKey: IPhoneMapAppearance.baseStyleDefaultsKey
                ),
                usesRealisticElevation: false
            )
            precondition(restored.baseStyle == style)
        }

        defaults.set(
            true,
            forKey: IPhoneMapAppearance.realisticElevationDefaultsKey
        )
        let restoredTerrain = IPhoneMapAppearance(
            persistedBaseStyleRawValue: IPhoneMapBaseStyle.standard.rawValue,
            usesRealisticElevation: defaults.bool(
                forKey: IPhoneMapAppearance.realisticElevationDefaultsKey
            )
        )
        precondition(restoredTerrain.usesRealisticElevation)
    }

    private static func testUnknownPersistedStyleFallsBackToStandard() {
        let appearance = IPhoneMapAppearance(
            persistedBaseStyleRawValue: "future-style",
            usesRealisticElevation: true
        )
        precondition(appearance.baseStyle == .standard)
        precondition(appearance.usesRealisticElevation)
    }

    private static func testConfigurationMapping() {
        for style in IPhoneMapBaseStyle.allCases {
            assertConfiguration(
                for: IPhoneMapAppearance(
                    baseStyle: style,
                    usesRealisticElevation: false
                ),
                expectedStyle: style,
                expectedElevation: .flat
            )
            assertConfiguration(
                for: IPhoneMapAppearance(
                    baseStyle: style,
                    usesRealisticElevation: true
                ),
                expectedStyle: style,
                expectedElevation: .realistic
            )
        }
    }

    private static func assertConfiguration(
        for appearance: IPhoneMapAppearance,
        expectedStyle: IPhoneMapBaseStyle,
        expectedElevation: MKMapConfiguration.ElevationStyle
    ) {
        let configuration = appearance.makeConfiguration()
        switch expectedStyle {
        case .standard:
            precondition(configuration is MKStandardMapConfiguration)
        case .satellite:
            precondition(configuration is MKImageryMapConfiguration)
        case .hybrid:
            precondition(configuration is MKHybridMapConfiguration)
        }
        precondition(configuration.elevationStyle == expectedElevation)
    }

    private static func testAppearanceEquality() {
        let standard = IPhoneMapAppearance.defaultValue
        precondition(standard == IPhoneMapAppearance.defaultValue)
        precondition(
            standard != IPhoneMapAppearance(
                baseStyle: .standard,
                usesRealisticElevation: true
            )
        )
    }

    private static func testIdempotentApplication() {
        let coordinator = MapViewContainer.Coordinator()
        let target = RecordingMapAppearanceTarget()
        let standard = IPhoneMapAppearance.defaultValue

        coordinator.applyAppearanceIfNeeded(standard, to: target)
        let firstConfiguration = target.preferredConfiguration
        precondition(target.assignmentCount == 1)
        precondition(coordinator.lastAppliedAppearance == standard)

        coordinator.applyAppearanceIfNeeded(standard, to: target)
        precondition(target.assignmentCount == 1)
        precondition(target.preferredConfiguration === firstConfiguration)

        let terrain = IPhoneMapAppearance(
            baseStyle: .standard,
            usesRealisticElevation: true
        )
        coordinator.applyAppearanceIfNeeded(terrain, to: target)
        precondition(target.assignmentCount == 2)
        precondition(coordinator.lastAppliedAppearance == terrain)
        precondition(
            target.preferredConfiguration.elevationStyle == .realistic
        )
    }

    private static func testMapPitchControlTargets() {
        precondition(!MapViewControlState.isPitched(0))
        precondition(!MapViewControlState.isPitched(5))
        precondition(MapViewControlState.isPitched(5.01))
        precondition(
            MapViewControlState.targetPitch(isCurrentlyPitched: false) == 45
        )
        precondition(
            MapViewControlState.targetPitch(isCurrentlyPitched: true) == 0
        )
    }
}
