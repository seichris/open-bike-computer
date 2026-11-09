import CryptoKit
import Foundation

/// Apple Maps routes saved with normalization version 1 are read with version
/// 2 when an archive is loaded. Their bytes, hash and identity stay as saved.
extension RideSharedTests {
    static func testLegacyMapKitRoutes() throws {
        let createdAt = Date(timeIntervalSince1970: 1_790_000_000)
        try testInvalidVersion1ArchiveIsRejectedUnread(createdAt: createdAt)

        // Outside mainland China, Apple Maps coordinates are WGS-84 and the
        // road itself. Version 1 shifted them anyway.
        for (name, road) in [
            ("Hong Kong", line(from: (22.2810, 114.1600), to: (22.2990, 114.1720), count: 30)),
            ("Singapore", line(from: (1.2800, 103.8500), to: (1.2980, 103.8640), count: 30)),
        ] {
            let stored = road.map(version1)
            require(zip(stored, road).allSatisfy { NavigationGeometryV1.distance(from: $0, to: $1) > 130 },
                "\(name): version 1 saved the route more than 130 m off the road")
            let saved = try NavigationRouteArchiveV1.create(
                route: route(stored, version: 1), createdAt: createdAt, purpose: .offlineNavigation)
            let data = try saved.encoded(purpose: .offlineNavigation, now: createdAt)
            let loaded = try NavigationRouteArchiveV1.decode(data, purpose: .offlineNavigation, now: createdAt)
            require(onRoad(loaded.route.points, road),
                "\(name): a loaded version-1 route follows the road again")
            require(loaded.route.points.enumerated().allSatisfy { index, point in
                    let drawn = GCJ02.fromWGS84(latitude: stored[index].latitude, longitude: stored[index].longitude)
                    return point.latitude == drawn.latitude && point.longitude == drawn.longitude
                },
                "\(name): each point is where the phone drew it before version 2")
            require(loaded.route.normalizationVersion == RouteCoordinateNormalizationV1.mapKitVersion &&
                loaded.route.source == RouteEndpointV1(coordinate: loaded.route.points[0], label: "Start") &&
                loaded.route.destination == RouteEndpointV1(coordinate: loaded.route.points[29], label: "Finish") &&
                loaded.route.bounds == RouteBoundsV1.enclosing(loaded.route.points) &&
                loaded.route.steps == saved.storedRoute.steps &&
                loaded.route.distanceMeters == saved.storedRoute.distanceMeters &&
                loaded.route.id == saved.routeID && loaded.route.revision == saved.revision &&
                loaded.route.provider == RouteProviderPolicyV1.mapKitSavedOnPhone &&
                (try? loaded.route.validate()) != nil,
                "\(name): the reread route is a valid version-2 route with the same endpoints' labels and steps")
            try requireUnchangedIdentity(loaded, saved: saved, data: data, createdAt: createdAt, name: name)
            require(NavigationRouteArchiveV1(
                    schemaVersion: saved.schemaVersion, storedRoute: saved.storedRoute,
                    createdAt: saved.createdAt, deleteAfter: saved.deleteAfter,
                    contentHash: saved.contentHash) == loaded,
                "\(name): creating and loading an archive read it the same way")
        }

        // Mainland China: Apple Maps coordinates are GCJ-02, and versions 1
        // and 2 read them the same way.
        let lanzhou = line(from: (36.0611, 103.8343), to: (36.0790, 103.8560), count: 30)
        try requireUnchanged(lanzhou.map { version1(RouteCoordinateNormalizationV1.wgs84ToMapKit($0)) },
            road: lanzhou, createdAt: createdAt, "A version-1 mainland route")

        // Version 2 and other providers already hold WGS-84.
        let hongKong = line(from: (22.2810, 114.1600), to: (22.2990, 114.1720), count: 30)
        try requireUnchanged(hongKong, road: hongKong, version: 2, createdAt: createdAt, "A version-2 Hong Kong route")
        try requireUnchanged(hongKong, road: hongKong, provider: RouteProviderPolicyV1.importedGPX,
            createdAt: createdAt, "A GPX route in Hong Kong, also version 1,")
        let london = line(from: (51.5000, -0.1000), to: (51.5180, -0.1200), count: 30)
        try requireUnchanged(london.map(version1), road: london, createdAt: createdAt,
            "A version-1 route outside the old rectangle")

        // Osaka straddles the rectangle's eastern edge at 135.5° E: version 1
        // shifted only the western part of this route.
        let osaka = line(from: (34.6900, 135.4500), to: (34.7000, 135.5500), count: 60)
        let osakaStored = osaka.map(version1)
        require(zip(osakaStored, osaka).allSatisfy { stored, road in
                road.longitude > 135.5 ? stored == road : NavigationGeometryV1.distance(from: stored, to: road) > 500
            },
            "Version 1 shifted the Osaka route west of 135.5° E only")
        require(onRoad(try load(osakaStored, createdAt: createdAt).route.points, osaka),
            "Both sides of the old rectangle's edge are read correctly")

        // Beside the Hong Kong border a Hong Kong position shares its Apple
        // Maps coordinate with a mainland one. Version 1 always saved the
        // mainland reading.
        let strip = (0..<25).map {
            RouteCoordinateV1(latitude: 22.502 + Double($0) * 0.0002, longitude: 114.049 + Double($0) * 0.0004)
        }
        let south = strip + line(from: (22.5068, 114.0586), to: (22.4400, 114.0300), count: 30)
        require(RouteCoordinateNormalizationV1.isInMainlandChina(RouteCoordinateNormalizationV1.mapKitToWGS84(south[0])) &&
            !onRoad(RouteCoordinateNormalizationV1.mapKitToWGS84(south, startingNear: nil), south),
            "This Hong Kong route starts where its Apple Maps coordinates also read as mainland")
        require(onRoad(try load(south.map(version1), createdAt: createdAt).route.points, south),
            "A Hong Kong route starting beside the border takes the side of its first unambiguous point")
        let north = Array(south.reversed())
        require(onRoad(try load(north.map(version1), createdAt: createdAt).route.points, north),
            "A Hong Kong route ending beside the border keeps its side up to the end")
        require(try load(strip.map(version1), createdAt: createdAt).route.points == strip.map(version1),
            "A route wholly beside the border, with no unambiguous point, keeps the mainland reading")

        // A Shenzhen route along the border: some Apple Maps coordinates lie
        // in Hong Kong, yet every point reads as mainland.
        let shenzhenStrip = (0...30).map {
            RouteCoordinateV1(latitude: 22.5320 + Double($0) * 0.0002, longitude: 114.1180 + Double($0) * 0.0003)
        }
        let shenzhen = shenzhenStrip + line(from: (22.5380, 114.1270), to: (22.6000, 114.1300), count: 30)
        let shenzhenMapKit = shenzhen.map(RouteCoordinateNormalizationV1.wgs84ToMapKit)
        require(shenzhenMapKit.contains { !RouteCoordinateNormalizationV1.isInMainlandChina($0) },
            "The Shenzhen route's Apple Maps coordinates cross into Hong Kong")
        try requireUnchanged(shenzhenMapKit.map(version1), road: shenzhen, createdAt: createdAt,
            "A version-1 Shenzhen route along the border")

        // Long routes are read in runs; a point beside the border takes the
        // side the previous run ended on. These runs end clear of the border,
        // one in Hong Kong and one in Shenzhen.
        let hongKongReturn = line(from: (22.4770, 114.0520), to: (22.4800, 114.0520), count: 64) + Array(strip[10...])
        require(onRoad(try load(hongKongReturn.map(version1), createdAt: createdAt).route.points, hongKongReturn),
            "A Hong Kong route reaching the border after a long run keeps Hong Kong")
        let shenzhenReturn = line(from: (22.5590, 114.1040), to: (22.5560, 114.1040), count: 64) + shenzhenStrip
        try requireUnchanged(shenzhenReturn.map { version1(RouteCoordinateNormalizationV1.wgs84ToMapKit($0)) },
            road: shenzhenReturn, createdAt: createdAt, "A Shenzhen route reaching the border after a long run")

        // Crossing from Shenzhen into Hong Kong at Lok Ma Chau, then back to
        // the border after the first run, a route reads as version 2 reads it
        // from the same start.
        let crossingShenzhen = line(from: (22.5600, 114.0700), to: (22.5200, 114.0680), count: 25)
        let crossingHongKong = line(from: (22.5150, 114.0660), to: (22.4750, 114.0600), count: 39) + Array(strip[10...])
        let crossingMapKit = crossingShenzhen.map(RouteCoordinateNormalizationV1.wgs84ToMapKit) + crossingHongKong
        let crossing = try load(crossingMapKit.map(version1), createdAt: createdAt).route.points
        let fresh = RouteCoordinateNormalizationV1.mapKitToWGS84(crossingMapKit, startingNear: crossingShenzhen[0])
        require(onRoad(crossing, fresh) &&
            onRoad(Array(crossing.suffix(25)), Array(crossingHongKong.suffix(25))),
            "A route across the border reads like a version-2 route from its start")

        // A reading that would break the route's device encoding keeps the
        // stored route: this Hong Kong segment spans the full 16-bit window.
        let start = version1(RouteCoordinateV1(latitude: 22.3200, longitude: 114.1000))
        let west = (start.longitude * 1_000_000).rounded() - 32_767
        let wide = [start, RouteCoordinateV1(latitude: start.latitude, longitude: west / 1_000_000)]
        let shiftedEnds = wide.map { GCJ02.fromWGS84(latitude: $0.latitude, longitude: $0.longitude) }
        require(NavigationGeometryV1.isRouteWindowDeltaEncodable(from: wide[0], to: wide[1]) &&
            !NavigationGeometryV1.isRouteWindowDeltaEncodable(
                from: RouteCoordinateV1(latitude: shiftedEnds[0].latitude, longitude: shiftedEnds[0].longitude),
                to: RouteCoordinateV1(latitude: shiftedEnds[1].latitude, longitude: shiftedEnds[1].longitude)),
            "Reading this segment with version 2 would exceed the device delta range")
        let kept = try load(wide, createdAt: createdAt)
        require(kept.route == kept.storedRoute,
            "A reading that would make the route invalid leaves it as stored")
    }

    /// Version 1's normalization exactly as the app ran it before version 2.
    /// Decoding reads a version-1 route before it validates the stored one. An
    /// archive that validation rejects, here a shared Hong Kong route with one
    /// latitude of 1e300, is never read again and still fails to decode.
    private static func testInvalidVersion1ArchiveIsRejectedUnread(createdAt: Date) throws {
        let stored = line(from: (22.2810, 114.1600), to: (22.2990, 114.1720), count: 30).map(version1)
        let saved = try NavigationRouteArchiveV1.create(
            route: route(stored, version: 1), createdAt: createdAt, purpose: .offlineNavigation)
        let data = try saved.encoded(purpose: .offlineNavigation, now: createdAt)
        guard var archive = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var routeObject = archive["route"] as? [String: Any],
              var points = routeObject["points"] as? [[String: Any]] else {
            require(false, "the encoded archive has a route with points")
            return
        }
        points[15]["latitude"] = 1e300
        routeObject["points"] = points
        archive["route"] = routeObject
        let corrupt = try JSONSerialization.data(withJSONObject: archive)
        let decodedRoute = try JSONDecoder().decode(
            NavigationRouteV1.self,
            from: JSONSerialization.data(withJSONObject: routeObject)
        )
        require(RouteCoordinateNormalizationV1.rereadVersion1(decodedRoute) == decodedRoute,
            "a version-1 route with an invalid coordinate is returned as stored")
        var rejected = false
        do {
            _ = try NavigationRouteArchiveV1.decode(corrupt, purpose: .offlineNavigation, now: createdAt)
        } catch {
            rejected = true
        }
        require(rejected, "a version-1 archive with an invalid coordinate fails to decode")
    }

    private static func version1(_ coordinate: RouteCoordinateV1) -> RouteCoordinateV1 {
        func inRectangle(_ latitude: Double, _ longitude: Double) -> Bool {
            latitude >= 0.8293 && latitude <= 55.8271 && longitude >= 72.004 && longitude <= 135.5
        }
        guard inRectangle(coordinate.latitude, coordinate.longitude) else { return coordinate }
        var latitude = coordinate.latitude
        var longitude = coordinate.longitude
        for _ in 0..<3 {
            let projected = inRectangle(latitude, longitude)
                ? GCJ02.fromWGS84(latitude: latitude, longitude: longitude)
                : (latitude: latitude, longitude: longitude)
            latitude += coordinate.latitude - projected.latitude
            longitude += coordinate.longitude - projected.longitude
        }
        return RouteCoordinateV1(latitude: latitude, longitude: longitude)
    }

    private static func line(
        from start: (Double, Double),
        to end: (Double, Double),
        count: Int
    ) -> [RouteCoordinateV1] {
        (0..<count).map { index in
            let fraction = Double(index) / Double(count - 1)
            return RouteCoordinateV1(
                latitude: start.0 + (end.0 - start.0) * fraction,
                longitude: start.1 + (end.1 - start.1) * fraction
            )
        }
    }

    private static func route(
        _ points: [RouteCoordinateV1],
        provider: RouteProviderMetadataV1 = RouteProviderPolicyV1.mapKitSavedOnPhone,
        version: UInt16
    ) -> NavigationRouteV1 {
        NavigationRouteV1(
            id: UUID(uuidString: "0D5C3F7A-2B61-4C8E-9A4D-1E2F3A4B5C6D")!,
            revision: 1,
            provider: provider,
            localeIdentifier: "en_HK",
            transportType: .cycling,
            source: RouteEndpointV1(coordinate: points[0], label: "Start"),
            destination: RouteEndpointV1(coordinate: points[points.count - 1], label: "Finish"),
            bounds: RouteBoundsV1.enclosing(points)!,
            distanceMeters: 2_400,
            expectedTravelTimeSeconds: 600,
            name: "Saved ride",
            points: points,
            steps: [NavigationRouteStepV1(
                id: 1,
                geometryStartIndex: 0,
                geometryEndIndex: points.count - 1,
                instruction: "Ride to the finish",
                maneuver: .straight,
                distanceMeters: 2_400
            )],
            normalizationVersion: version
        )
    }

    private static func load(
        _ stored: [RouteCoordinateV1],
        provider: RouteProviderMetadataV1 = RouteProviderPolicyV1.mapKitSavedOnPhone,
        version: UInt16 = 1,
        createdAt: Date
    ) throws -> NavigationRouteArchiveV1 {
        let saved = try NavigationRouteArchiveV1.create(
            route: route(stored, provider: provider, version: version),
            createdAt: createdAt,
            purpose: .offlineNavigation
        )
        return try NavigationRouteArchiveV1.decode(
            saved.encoded(purpose: .offlineNavigation, now: createdAt),
            purpose: .offlineNavigation,
            now: createdAt
        )
    }

    private static func requireUnchanged(
        _ stored: [RouteCoordinateV1],
        road: [RouteCoordinateV1],
        provider: RouteProviderMetadataV1 = RouteProviderPolicyV1.mapKitSavedOnPhone,
        version: UInt16 = 1,
        createdAt: Date,
        _ name: String
    ) throws {
        let saved = try NavigationRouteArchiveV1.create(
            route: route(stored, provider: provider, version: version),
            createdAt: createdAt,
            purpose: .offlineNavigation
        )
        let data = try saved.encoded(purpose: .offlineNavigation, now: createdAt)
        let loaded = try NavigationRouteArchiveV1.decode(data, purpose: .offlineNavigation, now: createdAt)
        require(loaded.route == loaded.storedRoute && loaded.storedRoute == saved.storedRoute &&
            loaded.route.normalizationVersion == version && onRoad(loaded.route.points, road),
            "\(name) is loaded exactly as stored, on the road")
        try requireUnchangedIdentity(loaded, saved: saved, data: data, createdAt: createdAt, name: name)
    }

    /// Loading keeps everything that identifies a revision: the stored route,
    /// its bytes and hash, the library and Watch identity, the elevation
    /// binding's fields and the file a store keeps it in.
    private static func requireUnchangedIdentity(
        _ loaded: NavigationRouteArchiveV1,
        saved: NavigationRouteArchiveV1,
        data: Data,
        createdAt: Date,
        name: String
    ) throws {
        let hashPayload = try loaded.socialHashPayload()
        let savedHashPayload = try saved.socialHashPayload()
        let encoded = try loaded.encoded(purpose: .offlineNavigation, now: createdAt)
        require(loaded.storedRoute == saved.storedRoute && loaded.contentHash == saved.contentHash &&
            (try? loaded.validate(purpose: .offlineNavigation, now: createdAt)) != nil &&
            encoded == data && hashPayload == savedHashPayload &&
            SHA256.hash(data: hashPayload).map { String(format: "%02x", $0) }.joined() == saved.contentHash &&
            WatchRouteIdentityV1(archive: loaded) == WatchRouteIdentityV1(archive: saved),
            "\(name): loading keeps the stored route, its bytes and its content hash")
        let summary = PlannedRouteSummaryV1(archive: loaded)
        require(summary.id == saved.routeID && summary.revision == saved.revision &&
            summary.contentHash == saved.contentHash && summary.providerID == saved.providerID &&
            summary.source == loaded.route.source && summary.destination == loaded.route.destination,
            "\(name): the library row keeps its identity and shows the route it navigates")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-mapkit-routes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NavigationRouteFileStoreV1(rootDirectory: root)
        let installed = try store.install(data, now: createdAt)
        let record = try store.record(matching: WatchRouteIdentityV1(archive: saved), now: createdAt)
        let written = try Data(contentsOf: record.fileURL)
        let pruned = store.pruneInvalidAndExpired(now: createdAt)
        let kept = try Data(contentsOf: record.fileURL)
        require(installed.archive == loaded && record.archive == loaded &&
            record.fileURL.lastPathComponent.contains(saved.contentHash) &&
            written == data && pruned == 0 && kept == data,
            "\(name): a store keeps the archive's file and bytes, and validation keeps it")
    }

    /// Within a centimetre of the road at every point.
    private static func onRoad(_ points: [RouteCoordinateV1], _ road: [RouteCoordinateV1]) -> Bool {
        points.count == road.count && zip(points, road).allSatisfy {
            NavigationGeometryV1.distance(from: $0, to: $1) < 0.01
        }
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAILED: \(message)") }
    }
}
