import Combine
import CoreLocation
import Foundation
import MapKit

/// A favorite starred from a saved route uses MapKit coordinates, like a map
/// pin, and favorites and recents stored before that are repaired.
extension OfflineRouteSaveTests {
    static func savedRouteFavoriteCoordinates() throws {
        let suite = "saved-route-favorites.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("saved-route-favorites-\(UUID())")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func library() -> PhoneRouteLibrary {
            PhoneRouteLibrary(store: NavigationRouteFileStoreV1(rootDirectory: root),
                connectivity: PhoneWatchConnectivityCoordinator(), defaults: defaults, now: { now })
        }
        func gpx(_ name: String, _ latitude: Double, _ longitude: Double) -> Data {
            Data(("<gpx version=\"1.1\"><trk><name>\(name)</name><trkseg>" +
                "<trkpt lat=\"\(latitude - 0.002)\" lon=\"\(longitude)\"/>" +
                "<trkpt lat=\"\(latitude)\" lon=\"\(longitude)\"/></trkseg></trk></gpx>").utf8)
        }
        func point(_ coordinate: RouteCoordinateV1) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        }
        func stored(_ destination: SavedDestination?) -> RouteCoordinateV1? {
            guard let latitude = destination?.latitude, let longitude = destination?.longitude else { return nil }
            return RouteCoordinateV1(latitude: latitude, longitude: longitude)
        }

        let installer = library()
        let bund = try installer.importGPX(gpx("Bund", 31.2304, 121.4737), fileName: "Bund.gpx")
        let jingAn = try installer.importGPX(gpx("Jing'an", 31.2286, 121.4480), fileName: "JingAn.gpx")
        let chengdu = try installer.importGPX(gpx("Chengdu", 30.6586, 104.0648), fileName: "Chengdu.gpx")
        let london = try installer.importGPX(gpx("Westminster", 51.5072, -0.1276), fileName: "Westminster.gpx")
        let wgs84 = bund.destination.coordinate
        let mapKit = RouteCoordinateNormalizationV1.wgs84ToMapKit(wgs84)

        let starred = SavedRouteFavoritePolicy.favorite(for: bund)
        check(starred.name == bund.destination.label && stored(starred) == mapKit &&
            NavigationGeometryV1.distance(from: wgs84, to: mapKit) > 100,
            "A route starred in mainland China becomes a MapKit-space favorite, not its WGS-84 archive point")
        guard case .mapItem(let item) = starred.routeEndpoint else {
            preconditionFailure("A starred route favorite has a coordinate")
        }
        let planned: CLLocationCoordinate2D
        if #available(iOS 26.0, macOS 26.0, *) {
            planned = item.location.coordinate
        } else {
            planned = item.placemark.coordinate
        }
        check(planned.latitude == mapKit.latitude && planned.longitude == mapKit.longitude,
            "Planning to the favorite targets the saved route's destination in MapKit space")
        check(stored(SavedRouteFavoritePolicy.favorite(for: london)) == london.destination.coordinate,
            "Outside the GCJ-02 region a starred route keeps its coordinates")

        // What the earlier star button stored, plus favorites the repair must not touch.
        let earlier = SavedDestinationStore(defaults: defaults)
        let legacy = SavedDestination(name: "Bund", coordinate: point(wgs84))
        earlier.addFavorite(legacy, savedRouteID: bund.id)
        // Planning to the favorite once left a copy with its ID and link in recents.
        earlier.addRecent(earlier.favoriteDestinations[0])
        earlier.addFavorite(SavedDestination(name: "Jing'an Temple",
            coordinate: CLLocationCoordinate2D(latitude: 31.2253, longitude: 121.4497)), savedRouteID: jingAn.id)
        earlier.addFavorite(SavedDestination(name: "Westminster",
            coordinate: point(london.destination.coordinate)), savedRouteID: london.id)
        earlier.addFavorite(SavedDestination(name: "Deleted route",
            coordinate: CLLocationCoordinate2D(latitude: 31.1, longitude: 121.3)), savedRouteID: UUID())
        earlier.addFavorite(SavedDestination(name: "Chengdu", coordinate: point(chengdu.destination.coordinate)))
        check(earlier.recentDestinations.first?.id == legacy.id &&
            earlier.recentDestinations.first?.savedRouteID == bund.id &&
            !earlier.nonFavoriteRecentDestinations.contains { $0.id == legacy.id },
            "Before the repair the recent copy shares the favorite's ID, link and point, so it stays hidden")

        // A relaunch reads everything back from storage before the repair runs.
        let store = SavedDestinationStore(defaults: defaults)
        let routes = library()
        let before = store.favoriteDestinations
        check(routes.routes.count == 4 && before == earlier.favoriteDestinations &&
            store.recentDestinations == earlier.recentDestinations,
            "The relaunched stores hold the earlier favorites, recents and routes")
        let repairs = SavedRouteFavoritePolicy.legacyCoordinateRepairs(destinations: before, routes: routes.routes)
        check(Set(repairs.keys) == [legacy.id] &&
            repairs[legacy.id].map { $0.latitude == mapKit.latitude && $0.longitude == mapKit.longitude } == true,
            "Only a favorite holding its linked route's exact WGS-84 destination in the GCJ-02 region is repaired")

        var publications = 0
        let observation = store.$favoriteDestinations.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        let persisted = defaults.data(forKey: "routeInput.favoriteDestinations")
        store.replaceCoordinates(favorites: [:], recents: [:])
        store.replaceCoordinates(favorites: [UUID(): point(mapKit)], recents: [UUID(): point(mapKit)])
        check(publications == 0 && store.favoriteDestinations == before &&
            defaults.data(forKey: "routeInput.favoriteDestinations") == persisted,
            "A repair with nothing to change neither publishes nor persists")

        let binding = SavedRouteFavoritePolicy.repairLegacyCoordinates(in: store, whenever: routes.$routes)
        defer { binding.cancel() }
        let repaired = store.favoriteDestinations
        check(publications == 1 && stored(store.favorite(savedRouteID: bund.id)) == mapKit,
            "Observing the installed routes repairs the favorite immediately")
        check(repaired.map(\.id) == before.map(\.id) && repaired.map(\.name) == before.map(\.name) &&
            repaired.map(\.savedRouteID) == before.map(\.savedRouteID) &&
            zip(repaired, before).filter { $0.0.id != legacy.id }.allSatisfy { $0.0 == $0.1 },
            "Only the legacy favorite's coordinate changes; identity, name, order and route link stay")
        let copy = store.recentDestinations.first { $0.id == legacy.id }
        check(stored(copy) == mapKit && copy?.savedRouteID == bund.id &&
            !store.nonFavoriteRecentDestinations.contains { $0.id == legacy.id },
            "Its copy in recents moves too, so no stale point resurfaces under Recent Searches")
        let synced = store.favoriteDestinations.compactMap { destination -> SyncedCoordinateFavoriteV1? in
            guard let coordinate = destination.coordinate else { return nil }
            return SyncedCoordinateFavoriteV1(id: destination.id, name: destination.name,
                coordinate: RouteCoordinateNormalizationV1.mapKitToWGS84(RouteCoordinateV1(
                    latitude: coordinate.latitude, longitude: coordinate.longitude)))
        }
        check(Set(synced.map(\.id)).count == synced.count &&
            (try? CoordinateFavoritesEnvelopeV1(revision: 1, favorites: synced).validated()) != nil &&
            synced.first { $0.id == legacy.id }.map {
                NavigationGeometryV1.distance(from: $0.coordinate, to: wgs84) < 0.5
            } == true,
            "The Watch favorite envelope stays valid and receives the saved route's own destination")

        _ = try routes.importGPX(gpx("Later", 51.52, -0.1), fileName: "Later.gpx")
        routes.reload()
        check(publications == 1 && store.favoriteDestinations == repaired &&
            SavedRouteFavoritePolicy.legacyCoordinateRepairs(
                destinations: store.recentDestinations, routes: routes.routes).isEmpty,
            "Later route changes never move a repaired favorite or recent again")
        let relaunched = SavedDestinationStore(defaults: defaults)
        check(relaunched.favoriteDestinations == repaired &&
            relaunched.recentDestinations == store.recentDestinations,
            "The repair is persisted for favorites and recents")

        let section = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/Views/PlannedRoutesView.swift", encoding: .utf8)
        let app = try String(contentsOfFile: "ios-app/BikeComputer/BikeComputer/BikeComputerApp.swift", encoding: .utf8)
        check(section.contains("SavedRouteFavoritePolicy.favorite(for: route)") &&
            !section.contains("latitude: route.destination.coordinate.latitude"),
            "Starring a saved route creates its favorite in MapKit space")
        guard let repair = app.range(of: "SavedRouteFavoritePolicy.repairLegacyCoordinates(\n            in: destinationStore,\n            whenever: routeLibrary.$routes\n        )\n        .store(in: &cancellables)"),
              let watchSync = app.range(of: "destinationStore.$favoriteDestinations") else {
            preconditionFailure("The app delegate must keep the repair binding and the Watch favorite sync")
        }
        check(repair.lowerBound < watchSync.lowerBound,
            "The app repairs favorites before the Watch first syncs them")
    }
}
