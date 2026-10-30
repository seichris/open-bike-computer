import Foundation

/// Where Apple Maps uses GCJ-02 rather than WGS-84 coordinates: mainland
/// China, which excludes Hong Kong, Macau and Taiwan, plus the sea nearer to
/// its coast than to other land.
/// `ios-app/scripts/generate_mainland_china_region.py` builds the polygon from
/// Natural Earth; docs/mapkit-china-coordinates.md gives its sources and
/// precision.
nonisolated enum MainlandChinaRegion {
    enum Coverage: Equatable {
        case none
        case partial
        case all
    }

    /// Whether a WGS-84 position lies in the region.
    static func contains(latitude: Double, longitude: Double) -> Bool {
        guard boundsContain(latitude: latitude, longitude: longitude, margin: 0) else {
            return false
        }
        return polygon.contains(latitude: latitude, longitude: longitude)
    }

    /// How much of a WGS-84 latitude and longitude box lies in the region. An
    /// invalid box is never reported as uniformly inside or outside.
    static func coverage(south: Double, west: Double, north: Double, east: Double) -> Coverage {
        guard south.isFinite, west.isFinite, north.isFinite, east.isFinite,
              south <= north, west <= east else { return .partial }
        guard north >= Generated.south, south <= Generated.north,
              east >= Generated.west, west <= Generated.east else { return .none }
        if polygon.hasEdge(south: south, west: west, north: north, east: east) {
            return .partial
        }
        return polygon.contains(latitude: (south + north) / 2, longitude: (west + east) / 2)
            ? .all : .none
    }

    static var ringCount: Int { polygon.ringCount }
    static var vertexCount: Int { polygon.edges.count }

    fileprivate static func boundsContain(latitude: Double, longitude: Double, margin: Double) -> Bool {
        latitude >= Generated.south - margin && latitude <= Generated.north + margin &&
            longitude >= Generated.west - margin && longitude <= Generated.east + margin
    }

    private static let polygon = Polygon(
        base64: Generated.rings,
        unitsPerDegree: Generated.unitsPerDegree
    )

    /// Even-odd rings indexed by latitude band, so a lookup casts its ray only
    /// against the edges that can cross its latitude.
    private struct Polygon: Sendable {
        struct Edge: Sendable {
            let latitude0: Double
            let longitude0: Double
            let latitude1: Double
            let longitude1: Double
        }

        static let bandHeight = 0.1

        let ringCount: Int
        let edges: [Edge]
        let bandSouth: Double
        let bands: [[Int32]]

        init(base64: String, unitsPerDegree: Double) {
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
                preconditionFailure("The generated mainland China region is not base64")
            }
            var reader = VarintReader(bytes: [UInt8](data))
            var edges: [Edge] = []
            let ringCount = reader.next()
            for _ in 0..<ringCount {
                let vertexCount = reader.next()
                var latitude = 0
                var longitude = 0
                var ring: [(Double, Double)] = []
                ring.reserveCapacity(vertexCount)
                for _ in 0..<vertexCount {
                    latitude += reader.nextSigned()
                    longitude += reader.nextSigned()
                    ring.append((Double(latitude) / unitsPerDegree, Double(longitude) / unitsPerDegree))
                }
                for (index, start) in ring.enumerated() {
                    let end = ring[(index + 1) % ring.count]
                    edges.append(Edge(latitude0: start.0, longitude0: start.1,
                                      latitude1: end.0, longitude1: end.1))
                }
            }
            precondition(reader.isAtEnd, "The generated mainland China region has trailing bytes")

            let south = edges.map { min($0.latitude0, $0.latitude1) }.min() ?? 0
            let north = edges.map { max($0.latitude0, $0.latitude1) }.max() ?? 0
            let count = Int(((north - south) / Self.bandHeight).rounded(.down)) + 1
            var bands = [[Int32]](repeating: [], count: count)
            func band(_ latitude: Double) -> Int {
                min(max(Int(((latitude - south) / Self.bandHeight).rounded(.down)), 0), count - 1)
            }
            for (index, edge) in edges.enumerated() {
                let first = band(min(edge.latitude0, edge.latitude1))
                let last = band(max(edge.latitude0, edge.latitude1))
                for value in first...last {
                    bands[value].append(Int32(index))
                }
            }
            self.ringCount = ringCount
            self.edges = edges
            self.bandSouth = south
            self.bands = bands
        }

        func band(_ latitude: Double) -> Int {
            min(max(Int(((latitude - bandSouth) / Self.bandHeight).rounded(.down)), 0), bands.count - 1)
        }

        func contains(latitude: Double, longitude: Double) -> Bool {
            var inside = false
            for index in bands[band(latitude)] {
                let edge = edges[Int(index)]
                guard (edge.latitude0 > latitude) != (edge.latitude1 > latitude) else { continue }
                let crossing = edge.longitude0 + (latitude - edge.latitude0) *
                    (edge.longitude1 - edge.longitude0) / (edge.latitude1 - edge.latitude0)
                if longitude < crossing {
                    inside.toggle()
                }
            }
            return inside
        }

        func hasEdge(south: Double, west: Double, north: Double, east: Double) -> Bool {
            for value in band(south)...band(north) {
                for index in bands[value] where Self.segment(edges[Int(index)], meets: (south, west, north, east)) {
                    return true
                }
            }
            return false
        }

        /// Liang–Barsky clipping against the closed box.
        private static func segment(
            _ edge: Edge,
            meets box: (south: Double, west: Double, north: Double, east: Double)
        ) -> Bool {
            let longitudeDelta = edge.longitude1 - edge.longitude0
            let latitudeDelta = edge.latitude1 - edge.latitude0
            var entry = 0.0
            var exit = 1.0
            for (p, q) in [
                (-longitudeDelta, edge.longitude0 - box.west),
                (longitudeDelta, box.east - edge.longitude0),
                (-latitudeDelta, edge.latitude0 - box.south),
                (latitudeDelta, box.north - edge.latitude0),
            ] {
                if p == 0 {
                    if q < 0 { return false }
                    continue
                }
                let ratio = q / p
                if p < 0 {
                    if ratio > exit { return false }
                    entry = max(entry, ratio)
                } else {
                    if ratio < entry { return false }
                    exit = min(exit, ratio)
                }
            }
            return true
        }
    }

    private struct VarintReader {
        let bytes: [UInt8]
        var offset = 0

        var isAtEnd: Bool { offset == bytes.count }

        mutating func next() -> Int {
            var value = 0
            var shift = 0
            while true {
                precondition(offset < bytes.count && shift < 63,
                             "The generated mainland China region is truncated")
                let byte = bytes[offset]
                offset += 1
                value |= Int(byte & 0x7F) << shift
                guard byte & 0x80 != 0 else { return value }
                shift += 7
            }
        }

        mutating func nextSigned() -> Int {
            let value = next()
            return (value >> 1) ^ -(value & 1)
        }
    }
}

/// GCJ-02, the offset coordinates Apple Maps uses in mainland China.
nonisolated enum GCJ02 {
    private static let earthSemiMajorAxis = 6_378_245.0
    private static let eccentricitySquared = 0.00669342162296594323

    /// The Apple Maps coordinate for a WGS-84 position: GCJ-02 inside
    /// `MainlandChinaRegion`, unchanged elsewhere.
    static func mapKit(
        fromWGS84 latitude: Double,
        longitude: Double
    ) -> (latitude: Double, longitude: Double) {
        guard MainlandChinaRegion.contains(latitude: latitude, longitude: longitude) else {
            return (latitude, longitude)
        }
        return fromWGS84(latitude: latitude, longitude: longitude)
    }

    /// The WGS-84 position for an Apple Maps coordinate. Near a mainland
    /// border GCJ-02 moves mainland positions a few hundred metres, onto
    /// coordinates that positions across the border keep unchanged. Such a
    /// coordinate is read as GCJ-02 whenever its GCJ-02 preimage lies in the
    /// region, so every mainland position round-trips exactly; a position
    /// across the border within that distance may be read as mainland.
    static func wgs84(
        fromMapKit latitude: Double,
        longitude: Double
    ) -> (latitude: Double, longitude: Double) {
        // GCJ-02 offsets stay below 0.02 degrees, so nothing farther from the
        // region can have its preimage inside it.
        guard MainlandChinaRegion.boundsContain(latitude: latitude, longitude: longitude, margin: 0.05) else {
            return (latitude, longitude)
        }
        let preimage = toWGS84(latitude: latitude, longitude: longitude)
        guard MainlandChinaRegion.contains(latitude: preimage.latitude, longitude: preimage.longitude) else {
            return (latitude, longitude)
        }
        return preimage
    }

    /// GCJ-02 for any WGS-84 position, without checking the region. Only
    /// content known to lie in mainland China, such as a topography overlay
    /// wholly inside the region, uses it directly.
    static func fromWGS84(
        latitude: Double,
        longitude: Double
    ) -> (latitude: Double, longitude: Double) {
        let x = longitude - 105
        let y = latitude - 35
        var latitudeDelta = transformLatitude(x: x, y: y)
        var longitudeDelta = transformLongitude(x: x, y: y)
        let radians = latitude / 180 * .pi
        var magic = sin(radians)
        magic = 1 - eccentricitySquared * magic * magic
        let squareRoot = sqrt(magic)
        latitudeDelta = latitudeDelta * 180 /
            ((earthSemiMajorAxis * (1 - eccentricitySquared)) /
                (magic * squareRoot) * .pi)
        longitudeDelta = longitudeDelta * 180 /
            (earthSemiMajorAxis / squareRoot * cos(radians) * .pi)
        return (latitude + latitudeDelta, longitude + longitudeDelta)
    }

    /// The inverse of `fromWGS84`, found iteratively to well under a metre.
    static func toWGS84(
        latitude: Double,
        longitude: Double
    ) -> (latitude: Double, longitude: Double) {
        var wgs84 = (latitude: latitude, longitude: longitude)
        for _ in 0..<3 {
            let projected = fromWGS84(latitude: wgs84.latitude, longitude: wgs84.longitude)
            wgs84.latitude += latitude - projected.latitude
            wgs84.longitude += longitude - projected.longitude
        }
        return wgs84
    }

    private static func transformLatitude(x: Double, y: Double) -> Double {
        var value = -100 + 2 * x + 3 * y + 0.2 * y * y +
            0.1 * x * y + 0.2 * sqrt(abs(x))
        value += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        value += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        value += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return value
    }

    private static func transformLongitude(x: Double, y: Double) -> Double {
        var value = 300 + x + 2 * y + 0.1 * x * x +
            0.1 * x * y + 0.1 * sqrt(abs(x))
        value += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        value += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        value += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return value
    }
}
