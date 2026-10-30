import Foundation

/// Apple Maps uses GCJ-02 only in mainland China. The iPhone and the Watch
/// share this region and its conversions.
extension RideSharedTests {
    static func testMainlandChinaRegion() throws {
        require(MainlandChinaRegion.ringCount == MainlandChinaRegion.Generated.ringCount &&
            MainlandChinaRegion.vertexCount == MainlandChinaRegion.Generated.vertexCount,
            "The generated region decodes completely")

        struct Probes: Decodable { let points: [[Double]] }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mainland-china-region-probes.json")
        let probes = try JSONDecoder().decode(Probes.self, from: Data(contentsOf: fixture)).points
        let disagreements = probes.filter {
            MainlandChinaRegion.contains(latitude: $0[0], longitude: $0[1]) != ($0[2] == 1)
        }
        require(probes.count > 1_000 && disagreements.isEmpty,
            "Lookups agree with the generator on every probe, near the edge too: \(disagreements.prefix(3))")

        let places: [(name: String, latitude: Double, longitude: Double, mainland: Bool)] = [
            ("Shenzhen", 22.5431, 114.0579, true),
            ("Sheung Shui, Hong Kong", 22.5011, 114.1281, false),
            ("Central, Hong Kong", 22.2810, 114.1600, false),
            ("Zhuhai", 22.2700, 113.5650, true),
            ("Macau", 22.1935, 113.5398, false),
            ("Xiamen", 24.4798, 118.0894, true),
            ("Kinmen", 24.4340, 118.3180, false),
            ("Nangan, Matsu", 26.1550, 119.9350, false),
            ("Dandong", 40.1600, 124.3800, true),
            ("Sinuiju", 40.0700, 124.4400, false),
            ("Taipei", 25.0330, 121.5654, false),
            ("Singapore", 1.3050, 103.8550, false),
            ("Seoul", 37.5665, 126.9780, false),
            ("Bangkok", 13.7563, 100.5018, false),
            ("Lanzhou", 36.0611, 103.8343, true),
            ("East China Sea off Shanghai", 31.0000, 122.6000, true),
        ]
        for place in places {
            let coordinate = RouteCoordinateV1(latitude: place.latitude, longitude: place.longitude)
            let mapKit = RouteCoordinateNormalizationV1.wgs84ToMapKit(coordinate)
            require(RouteCoordinateNormalizationV1.isInMainlandChina(coordinate) == place.mainland,
                "\(place.name) is \(place.mainland ? "inside" : "outside") mainland China")
            if place.mainland {
                require(NavigationGeometryV1.distance(from: coordinate, to: mapKit) > 100 &&
                    NavigationGeometryV1.distance(
                        from: RouteCoordinateNormalizationV1.mapKitToWGS84(mapKit), to: coordinate) < 0.5,
                    "\(place.name) shifts into GCJ-02 and round-trips")
            } else {
                require(mapKit == coordinate && RouteCoordinateNormalizationV1.mapKitToWGS84(coordinate) == coordinate,
                    "Apple Maps coordinates in \(place.name) are WGS-84 and never shifted")
            }
        }

        // GCJ-02 moves this Luohu position onto Hong Kong coordinates. It still
        // round-trips: a coordinate with a mainland preimage reads as GCJ-02.
        let luohu = RouteCoordinateV1(latitude: 22.5320, longitude: 114.1180)
        let luohuMapKit = RouteCoordinateNormalizationV1.wgs84ToMapKit(luohu)
        require(RouteCoordinateNormalizationV1.isInMainlandChina(luohu) &&
            !RouteCoordinateNormalizationV1.isInMainlandChina(luohuMapKit) &&
            NavigationGeometryV1.distance(
                from: RouteCoordinateNormalizationV1.mapKitToWGS84(luohuMapKit), to: luohu) < 0.5,
            "A mainland position shifted across the border still round-trips")
        // Without a reference, this Hong Kong position a few hundred metres
        // from the border shares its Apple Maps coordinate with a mainland
        // position and reads as that position.
        let hongKong = RouteCoordinateV1(latitude: 22.5075, longitude: 114.0610)
        let read = RouteCoordinateNormalizationV1.mapKitToWGS84(hongKong)
        require(!RouteCoordinateNormalizationV1.isInMainlandChina(hongKong) &&
            RouteCoordinateNormalizationV1.wgs84ToMapKit(hongKong) == hongKong &&
            RouteCoordinateNormalizationV1.isInMainlandChina(read) &&
            NavigationGeometryV1.distance(from: RouteCoordinateNormalizationV1.wgs84ToMapKit(read), to: hongKong) < 0.5,
            "Near the border an ambiguous Apple Maps coordinate reads as mainland by default")

        // A known nearby position settles the two readings, so a GPS fix sent
        // into Apple Maps space comes back on its own side of the border.
        let lokMaChau = RouteCoordinateV1(latitude: 22.5143, longitude: 114.0657)
        require(!RouteCoordinateNormalizationV1.isInMainlandChina(lokMaChau) &&
            NavigationGeometryV1.distance(
                from: RouteCoordinateNormalizationV1.mapKitToWGS84(lokMaChau), to: lokMaChau) > 500 &&
            RouteCoordinateNormalizationV1.mapKitToWGS84(lokMaChau, near: lokMaChau) == lokMaChau &&
            RouteCoordinateNormalizationV1.mapKitToWGS84(hongKong, near: hongKong) == hongKong &&
            NavigationGeometryV1.distance(
                from: RouteCoordinateNormalizationV1.mapKitToWGS84(hongKong, near: read), to: read) < 0.5 &&
            NavigationGeometryV1.distance(
                from: RouteCoordinateNormalizationV1.mapKitToWGS84(luohuMapKit, near: luohu), to: luohu) < 0.5,
            "A nearby reference settles a shared coordinate on either side of the border")
        let lanzhou = RouteCoordinateV1(latitude: 36.0611, longitude: 103.8343)
        require(NavigationGeometryV1.distance(
                from: RouteCoordinateNormalizationV1.mapKitToWGS84(
                    RouteCoordinateNormalizationV1.wgs84ToMapKit(lanzhou), near: hongKong),
                to: lanzhou) < 0.5,
            "A reference never changes an unambiguous coordinate")

        // Route geometry is read in order, each point near the one before it.
        // Heading south-east, the way GCJ-02 shifts, a Hong Kong route keeps
        // to Hong Kong even where its points are far from the start.
        let hongKongRoute = (0...30).map {
            RouteCoordinateV1(latitude: 22.5143 - Double($0) * 0.0003, longitude: 114.0657 + Double($0) * 0.0003)
        }
        let shenzhenRoute = (0...30).map {
            RouteCoordinateV1(latitude: 22.5320 + Double($0) * 0.0002, longitude: 114.1180 + Double($0) * 0.0003)
        }
        let shenzhenMapKit = shenzhenRoute.map(RouteCoordinateNormalizationV1.wgs84ToMapKit)
        require(hongKongRoute.allSatisfy { !RouteCoordinateNormalizationV1.isInMainlandChina($0) } &&
            hongKongRoute.contains {
                RouteCoordinateNormalizationV1.isInMainlandChina(RouteCoordinateNormalizationV1.mapKitToWGS84($0))
            } &&
            shenzhenRoute.allSatisfy(RouteCoordinateNormalizationV1.isInMainlandChina) &&
            shenzhenMapKit.contains { !RouteCoordinateNormalizationV1.isInMainlandChina($0) },
            "Both routes pass coordinates shared across the border")
        require(RouteCoordinateNormalizationV1.mapKitToWGS84(hongKongRoute, startingNear: lokMaChau) == hongKongRoute,
            "A Hong Kong route read from its start stays in Hong Kong")
        require(zip(RouteCoordinateNormalizationV1.mapKitToWGS84(shenzhenMapKit, startingNear: luohu), shenzhenRoute)
            .allSatisfy { NavigationGeometryV1.distance(from: $0.0, to: $0.1) < 0.5 },
            "A Shenzhen route along the border read from its start stays in Shenzhen")

        require(MainlandChinaRegion.coverage(south: 36.0, west: 103.7, north: 36.1, east: 103.9) == .all,
            "A Lanzhou selection lies wholly in the region")
        require(MainlandChinaRegion.coverage(south: 30.8, west: 121.2, north: 31.6, east: 122.5) == .all,
            "A Shanghai selection reaching out to sea stays wholly in the region")
        require(MainlandChinaRegion.coverage(south: 22.24, west: 114.13, north: 22.29, east: 114.22) == .none,
            "A Hong Kong Island selection lies wholly outside")
        require(MainlandChinaRegion.coverage(south: 22.45, west: 114.0, north: 22.6, east: 114.2) == .partial,
            "A selection across the Shenzhen and Hong Kong border is partial")
        require(MainlandChinaRegion.coverage(south: 51.4, west: -0.3, north: 51.6, east: 0.1) == .none,
            "A London selection lies wholly outside")
        require(MainlandChinaRegion.coverage(south: -90, west: -180, north: 90, east: 180) == .partial,
            "A box around the whole region is partial")
        require(MainlandChinaRegion.coverage(south: 36.1, west: 103.7, north: 36.0, east: 103.9) == .partial &&
            MainlandChinaRegion.coverage(south: .nan, west: 103.7, north: 36.1, east: 103.9) == .partial,
            "An invalid box is never reported as uniform")
        require(MainlandChinaRegion.coverage(south: -1e300, west: 103.7, north: 1e300, east: 103.9) == .partial,
            "A huge finite box is classified without trapping")
        require(!MainlandChinaRegion.contains(latitude: .nan, longitude: 104) &&
            !MainlandChinaRegion.contains(latitude: 36, longitude: .infinity),
            "Non-finite positions are outside")

        require(RouteCoordinateNormalizationV1.mapKitVersion == 2,
            "Routes normalized with the precise region are marked as normalization version 2")
    }

    private static func require(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAILED: \(message)") }
    }
}
