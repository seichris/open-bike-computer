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
        testInitialCamera()
        testUserTrackingChoicePersists()
        testRealisticTerrainOverlayPolicy()
        testBikeLanesTileTemplate()

        print("MapAppearanceTests passed")
    }

    private static func testDefaultAppearance() {
        precondition(
            IPhoneMapAppearance.defaultValue == IPhoneMapAppearance(
                baseStyle: .standard,
                usesRealisticElevation: true
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
                usesRealisticElevation: false
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
            usesRealisticElevation: false
        )
        coordinator.applyAppearanceIfNeeded(terrain, to: target)
        precondition(target.assignmentCount == 2)
        precondition(coordinator.lastAppliedAppearance == terrain)
        precondition(
            target.preferredConfiguration.elevationStyle == .flat
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

    private static func testInitialCamera() {
        let source = MKMapCamera(
            lookingAtCenter: CLLocationCoordinate2D(latitude: 1.3, longitude: 103.85),
            fromDistance: 1500, pitch: 0, heading: 28
        )
        let initial = MapViewControlState.initialCamera(from: source)
        precondition(abs(initial.pitch - 45) < 0.01)
        precondition(abs(initial.centerCoordinate.latitude - source.centerCoordinate.latitude) < 0.000001)
        precondition(abs(initial.centerCoordinate.longitude - source.centerCoordinate.longitude) < 0.000001)
        precondition(abs(initial.centerCoordinateDistance - source.centerCoordinateDistance) < 0.01)
        precondition(abs(initial.heading - source.heading) < 0.01)
        let chosen2D = MapViewControlState.initialCamera(from: source, pitch: 0)
        precondition(chosen2D.pitch == 0, "initial location centering must respect a prior 2D button choice")
    }

    private static func testUserTrackingChoicePersists() {
        precondition(
            !MapTrackingPolicy.shouldApplyDesiredMode(
                currentMode: .none,
                desiredMode: .follow,
                preservesCurrentTracking: true
            )
        )
        precondition(
            !MapTrackingPolicy.shouldApplyDesiredMode(
                currentMode: .none,
                desiredMode: .followWithHeading,
                preservesCurrentTracking: true
            )
        )
        precondition(
            MapTrackingPolicy.shouldApplyDesiredMode(
                currentMode: .follow,
                desiredMode: .none,
                preservesCurrentTracking: true
            )
        )
        precondition(
            !MapTrackingPolicy.shouldApplyDesiredMode(
                currentMode: .follow,
                desiredMode: .followWithHeading,
                preservesCurrentTracking: true
            )
        )
        precondition(
            MapTrackingPolicy.shouldApplyDesiredMode(
                currentMode: .none,
                desiredMode: .follow,
                preservesCurrentTracking: false
            )
        )
        precondition(
            !MapTrackingPolicy.shouldApplyDesiredMode(
                currentMode: .followWithHeading,
                desiredMode: .follow,
                preservesCurrentTracking: true
            ),
            "browsing GPS updates preserve heading mode selected with the button"
        )
        precondition(
            MapTrackingPolicy.shouldApplyDesiredMode(
                currentMode: .none,
                desiredMode: .followWithHeading,
                preservesCurrentTracking: false
            ),
            "starting navigation restores heading tracking after a pan"
        )
        precondition(
            MapTrackingPolicy.shouldApplyDesiredMode(
                currentMode: .followWithHeading,
                desiredMode: .follow,
                preservesCurrentTracking: false
            ),
            "stopping navigation restores the browsing default"
        )
    }

    private struct TerrainOverlays {
        var bikeLanes = false
        var contours = false
        var savedRoute = false
        var routeCreationLine = false
        var navigating = false
        var calculatedRoute = false
        var offlineRoute = false
        var detour = false

        var isPaused: Bool {
            RealisticTerrainOverlayPolicy.isPaused(
                showsBikeLanes: bikeLanes,
                showsContours: contours,
                showsSavedRoutePreview: savedRoute,
                hasRouteCreationLine: routeCreationLine,
                isNavigating: navigating,
                hasCalculatedRoute: calculatedRoute,
                hasOfflineRoute: offlineRoute,
                hasDetour: detour
            )
        }
    }

    private static func testRealisticTerrainOverlayPolicy() {
        precondition(!TerrainOverlays().isPaused, "an empty map keeps realistic ground")
        precondition(TerrainOverlays(bikeLanes: true).isPaused, "bike lanes flatten the ground")
        precondition(TerrainOverlays(contours: true).isPaused, "contours flatten the ground")
        precondition(TerrainOverlays(savedRoute: true).isPaused, "a saved-route preview flattens the ground")
        precondition(
            TerrainOverlays(routeCreationLine: true).isPaused,
            "a planned Create a Route line flattens the ground"
        )
        precondition(
            !TerrainOverlays(routeCreationLine: true, navigating: true).isPaused,
            "the map hides the Create a Route line during navigation"
        )
        precondition(
            TerrainOverlays(navigating: true, offlineRoute: true).isPaused,
            "an offline route being navigated flattens the ground"
        )
        precondition(
            TerrainOverlays(navigating: true, detour: true).isPaused,
            "a detour during navigation flattens the ground"
        )
        precondition(
            !TerrainOverlays(navigating: true, calculatedRoute: true).isPaused,
            "a MapKit Directions route follows the terrain"
        )
        precondition(
            !TerrainOverlays(offlineRoute: true).isPaused &&
                !TerrainOverlays(detour: true).isPaused,
            "the map draws offline and detour lines only while navigating"
        )
        precondition(
            !TerrainOverlays(navigating: true, calculatedRoute: true, offlineRoute: true).isPaused,
            "the map draws the offline line only without a calculated route"
        )

        for preference in [true, false] {
            precondition(
                !RealisticTerrainOverlayPolicy.displayedValue(preference: preference, isPaused: true),
                "a paused row reads unchecked"
            )
            precondition(
                RealisticTerrainOverlayPolicy.displayedValue(preference: preference, isPaused: false)
                    == preference,
                "removing the last overlay shows the saved preference, including off"
            )
            for requested in [true, false] {
                precondition(
                    RealisticTerrainOverlayPolicy.preference(
                        afterRequesting: requested, current: preference, isPaused: true
                    ) == preference,
                    "a write while paused keeps the saved preference"
                )
                precondition(
                    RealisticTerrainOverlayPolicy.preference(
                        afterRequesting: requested, current: preference, isPaused: false
                    ) == requested,
                    "an unpaused row saves the rider's choice"
                )
            }
        }
    }

    private static func testBikeLanesTileTemplate() {
        let path = "/cyclosm-lite/{z}/{x}/{y}.png"
        precondition(
            BikeLanesTileSource.urlTemplate(host: " Tiles.Example.com\n", path: " \(path) ")
                == "https://tiles.example.com/cyclosm-lite/{z}/{x}/{y}.png"
        )
        precondition(
            BikeLanesTileSource.urlTemplate(host: "tiles.example.com", path: "/{z}/{x}/{y}@{scale}x.png?v=2")
                == "https://tiles.example.com/{z}/{x}/{y}@{scale}x.png?v=2"
        )
        let rejectedHosts: [String?] = [
            nil, "", "https:", "https://tiles.example.com", "tiles.example.com/x",
            "tiles.example.com:8443", "user@tiles.example.com", "localhost",
            "127.0.0.1", "-tiles.example.com", "tiles..example.com", "tiles example.com",
        ]
        for host in rejectedHosts {
            precondition(
                BikeLanesTileSource.urlTemplate(host: host, path: path) == nil,
                "rejects tile host \(host ?? "nil")"
            )
        }
        let rejectedPaths: [String?] = [
            nil, "", "{z}/{x}/{y}.png", "/{z}/{x}.png", "//{z}/{x}/{y}.png",
            "/a//{z}/{x}/{y}.png", "/{z}/{x}/{y}.png#tile",
        ]
        for rejected in rejectedPaths {
            precondition(
                BikeLanesTileSource.urlTemplate(host: "tiles.example.com", path: rejected) == nil,
                "rejects tile path \(rejected ?? "nil")"
            )
        }

        precondition(BikeLanesTileSource.make(infoDictionary: [:]) == nil, "no tile service hides the layer")
        precondition(
            BikeLanesTileSource.make(infoDictionary: [
                BikeLanesTileSource.infoDictionaryHostKey: "",
                BikeLanesTileSource.infoDictionaryPathKey: "",
            ]) == nil,
            "the empty build settings hide the layer"
        )
        guard let overlay = BikeLanesTileSource.make(infoDictionary: [
            BikeLanesTileSource.infoDictionaryHostKey: "tiles.example.com",
            BikeLanesTileSource.infoDictionaryPathKey: path,
        ]) else { preconditionFailure("a valid tile service shows the layer") }
        precondition(overlay.urlTemplate == "https://tiles.example.com\(path)")
        precondition(!overlay.canReplaceMapContent && overlay.minimumZ == 13 && overlay.maximumZ == 18)
    }
}
