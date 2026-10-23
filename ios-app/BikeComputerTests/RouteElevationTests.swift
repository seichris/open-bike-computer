import Foundation

// Host tests for the shared route elevation contract. The fixtures under
// protocol/fixtures/route-elevation-v1 are generated from the backend
// reference (tools/generate_route_elevation_fixtures.py); the same bytes are
// decoded by the firmware host tests.

private typealias Contract = RouteElevationContractV1
private typealias DeviceProtocol = RouteElevationDeviceProtocolV1
private typealias Planner = RouteElevationDeliveryPlannerV1

private func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                    file: StaticString = #fileID, line: UInt = #line) {
    if !condition { fatalError("FAILED \(file):\(line): \(message())") }
}

private func close(_ left: Double?, _ right: Double?, _ tolerance: Double) -> Bool {
    switch (left, right) {
    case (nil, nil): true
    case let (left?, right?): abs(left - right) <= tolerance
    default: false
    }
}

private func closeArrays(_ left: [Double?], _ right: [Double?], _ tolerance: Double) -> Bool {
    left.count == right.count && zip(left, right).allSatisfy { close($0, $1, tolerance) }
}

private let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let fixtureDirectory = repositoryRoot.appendingPathComponent("protocol/fixtures/route-elevation-v1")

private struct ProcessingFixture: Decodable {
    struct Case: Decodable {
        struct Input: Decodable {
            let kind: String
            let rawElevationM: [Double?]?
            let vertexElevationM: [Double?]?
        }

        struct Span: Decodable {
            let kind: String
            let startM: Double
            let endM: Double
            let resolution: String
            let osmWayIds: [Int64]
            let reason: String?
        }

        struct Query: Decodable {
            let distanceM: Double
            let elevationM: Double?
            let elevationEstimated: Bool
            let gradePercent: Double?
            let gradeEstimated: Bool
            let ascentRemainingM: Double?
            let ascentRemainingLowerBound: Bool
        }

        struct Display: Decodable {
            let sampleIndex: Int
            let distanceM: UInt32
            let elevationM: Int16?
            let flags: UInt8
        }

        struct Expected: Decodable {
            let geometryDigest: String
            let lengthM: Double
            let spacingM: Double
            let sampleCount: Int
            let samples: RouteElevationProfileV1.Samples
            let statistics: RouteElevationProfileV1.Statistics
            let quality: RouteElevationProfileV1.Quality
            let structures: [RouteElevationProfileV1.Structure]
            let queries: [Query]
            let display: [Display]
        }

        let name: String
        let geometryE6: [[Int32]]
        let input: Input
        let structures: [Span]
        let expected: Expected

        var latitudeE6: [Int32] { geometryE6.map { $0[1] } }
        var longitudeE6: [Int32] { geometryE6.map { $0[0] } }
    }

    let profileSchema: String
    let processingVersion: String
    let displayMaximumPoints: Int
    let tolerances: [String: Double]
    let cases: [Case]
}

private func loadProcessingFixture() -> ProcessingFixture {
    let data = try! Data(contentsOf: fixtureDirectory.appendingPathComponent("processing.json"))
    return try! JSONDecoder().decode(ProcessingFixture.self, from: data)
}

private func loadTransferFixture() -> [String: Data] {
    let text = try! String(contentsOf: fixtureDirectory.appendingPathComponent("transfer-v1.txt"), encoding: .utf8)
    var values: [String: Data] = [:]
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: " ")
        guard parts.count == 2 else { continue }
        var bytes = Data()
        var index = parts[1].startIndex
        while index < parts[1].endIndex {
            let next = parts[1].index(index, offsetBy: 2)
            bytes.append(UInt8(parts[1][index..<next], radix: 16)!)
            index = next
        }
        values[String(parts[0])] = bytes
    }
    return values
}

private let fixtureSource = RouteElevationProfileV1.Source(
    kind: "internal-dem", id: "fixture-terrain", version: nil, verticalDatum: nil,
    nativeResolutionM: nil, surfaceModel: nil, interpolation: "fixture", attribution: [],
    retrievedAt: nil, qualification: "fixture"
)

/// The committed rounded document as a profile, exactly what the byte
/// fixtures were derived from.
private func fixtureProfile(_ item: ProcessingFixture.Case) -> RouteElevationProfileV1 {
    let vertices = item.input.kind == "vertices"
    return RouteElevationProfileV1(
        schema: Contract.profileSchema,
        processingVersion: Contract.processingVersion,
        geometry: .init(digest: item.expected.geometryDigest, pointCount: item.geometryE6.count,
                        lengthM: item.expected.lengthM, crs: "EPSG:4326", precision: "microdegrees"),
        sampling: .init(method: "uniform-distance", spacingM: item.expected.spacingM,
                        sampleCount: item.expected.sampleCount, smoothingHalfSamples: 1,
                        ascentHysteresisM: 5, gradeHalfWindowM: 100, maximumInterpolatedGapM: 200),
        source: vertices ? RouteElevationGPXTrustV1.source : fixtureSource,
        samples: item.expected.samples,
        structures: item.expected.structures,
        structureCorrection: .init(status: "unavailable", source: nil, sourceVersion: nil,
                                   attribution: [], reason: "fixture"),
        statistics: item.expected.statistics,
        quality: item.expected.quality
    )
}

private func testProcessingParity(_ fixture: ProcessingFixture) {
    expect(fixture.profileSchema == Contract.profileSchema, "profile schema")
    expect(fixture.processingVersion == Contract.processingVersion, "processing version")
    expect(fixture.displayMaximumPoints == DeviceProtocol.displayMaximumPoints, "display maximum")
    let tolerance = fixture.tolerances.values.max() ?? 0.11
    for item in fixture.cases {
        let geometry = try! RouteElevationProcessorV1.geometry(
            latitudeE6: item.latitudeE6, longitudeE6: item.longitudeE6
        )
        expect(geometry.digest == item.expected.geometryDigest, "\(item.name): geometry digest")
        expect(close(geometry.lengthMeters, item.expected.lengthM, tolerance), "\(item.name): length")
        let plan = RouteElevationProcessorV1.plan(length: geometry.lengthMeters)
        expect(plan.spacingMeters == item.expected.spacingM, "\(item.name): spacing")
        expect(plan.distancesMeters.count == item.expected.sampleCount, "\(item.name): sample count")
        let raw: [Double?]
        let source: RouteElevationProfileV1.Source
        if item.input.kind == "vertices" {
            raw = RouteElevationProcessorV1.resampleVertexElevations(
                geometry: geometry, plan: plan, vertexElevations: item.input.vertexElevationM!
            )!
            source = RouteElevationGPXTrustV1.source
        } else {
            raw = item.input.rawElevationM!
            source = fixtureSource
        }
        let spans = item.structures.map {
            RouteElevationStructureSpanV1(kind: $0.kind, startMeters: $0.startM, endMeters: $0.endM,
                                          resolution: $0.resolution, wayIDs: $0.osmWayIds, reason: $0.reason)
        }
        let profile = RouteElevationProcessorV1.process(
            geometry: geometry, plan: plan, rawElevations: raw, source: source, structures: spans
        )!
        let samples = profile.samples
        let expected = item.expected.samples
        expect(closeArrays(samples.distanceM, expected.distanceM, tolerance), "\(item.name): distances")
        expect(closeArrays(samples.elevationM, expected.elevationM, tolerance), "\(item.name): elevations")
        expect(closeArrays(samples.rawElevationM, expected.rawElevationM, tolerance), "\(item.name): raw")
        expect(closeArrays(samples.gradePercent, expected.gradePercent, tolerance), "\(item.name): grades")
        expect(closeArrays(samples.cumulativeAscentM, expected.cumulativeAscentM, tolerance),
               "\(item.name): cumulative ascent")
        expect(samples.flags == expected.flags, "\(item.name): sample flags")
        let statistics = profile.statistics
        let expectedStatistics = item.expected.statistics
        expect(close(statistics.totalAscentM, expectedStatistics.totalAscentM, tolerance), "\(item.name): ascent")
        expect(close(statistics.totalDescentM, expectedStatistics.totalDescentM, tolerance), "\(item.name): descent")
        expect(close(statistics.minimumElevationM, expectedStatistics.minimumElevationM, tolerance),
               "\(item.name): minimum")
        expect(close(statistics.maximumElevationM, expectedStatistics.maximumElevationM, tolerance),
               "\(item.name): maximum")
        expect(statistics.complete == expectedStatistics.complete &&
               statistics.includesEstimated == expectedStatistics.includesEstimated, "\(item.name): completeness")
        let quality = profile.quality
        let expectedQuality = item.expected.quality
        expect(quality.status == expectedQuality.status, "\(item.name): quality \(quality.status)")
        expect(quality.reasons == expectedQuality.reasons, "\(item.name): reasons \(quality.reasons)")
        expect(close(quality.coverage, expectedQuality.coverage, fixture.tolerances["coverage"] ?? 0.0002),
               "\(item.name): coverage")
        expect(close(quality.estimatedDistanceM, expectedQuality.estimatedDistanceM, tolerance) &&
               close(quality.unknownDistanceM, expectedQuality.unknownDistanceM, tolerance) &&
               close(quality.longestGapM, expectedQuality.longestGapM, tolerance), "\(item.name): quality distances")
        expect(profile.structures.count == item.expected.structures.count, "\(item.name): structure count")
        for (actual, wanted) in zip(profile.structures, item.expected.structures) {
            expect(actual.kind == wanted.kind && actual.resolution == wanted.resolution &&
                   actual.reason == wanted.reason && actual.osmWayIds == wanted.osmWayIds &&
                   close(actual.anchorStartM, wanted.anchorStartM, tolerance) &&
                   close(actual.anchorEndM, wanted.anchorEndM, tolerance), "\(item.name): structure")
        }
        try! profile.validate(expectedDigest: geometry.digest, expectedPointCount: geometry.pointCount)
    }
}

private func testDisplayAndQueries(_ fixture: ProcessingFixture) {
    for item in fixture.cases {
        let profile = fixtureProfile(item)
        let points = DeviceProtocol.displayPoints(profile)
        let expected = item.expected.display
        expect(points.count == expected.count, "\(item.name): display count \(points.count)")
        for (point, wanted) in zip(points, expected) {
            expect(point.sampleIndex == wanted.sampleIndex && point.distanceMeters == wanted.distanceM &&
                   point.elevationMeters == wanted.elevationM && point.flags == wanted.flags,
                   "\(item.name): display point \(wanted.sampleIndex)")
        }
        for query in item.expected.queries {
            let position = profile.position(atDistance: query.distanceM)
            expect(close(position.elevationMeters, query.elevationM, 1e-9) &&
                   position.elevationEstimated == query.elevationEstimated &&
                   close(position.gradePercent, query.gradePercent, 1e-9) &&
                   position.gradeEstimated == query.gradeEstimated &&
                   close(position.ascentRemainingMeters, query.ascentRemainingM, 1e-9) &&
                   position.ascentRemainingIsLowerBound == query.ascentRemainingLowerBound,
                   "\(item.name): query at \(query.distanceM)")
        }
    }
}

private func testTransferBytes(_ fixture: ProcessingFixture) {
    let bytes = loadTransferFixture()
    let cases = Dictionary(uniqueKeysWithValues: fixture.cases.map { ($0.name, $0) })
    let hill = fixtureProfile(cases["ordinary-hill"]!)
    let body = DeviceProtocol.encodeBody(hill, routeToken: 0x1234_5678, revision: 3,
                                         points: DeviceProtocol.displayPoints(hill))!
    expect(body == bytes["hill_body"], "hill body bytes")
    expect(String(format: "%08x", DeviceProtocol.crc32(body)) ==
           bytes["hill_body_crc32"]!.map { String(format: "%02x", $0) }.joined(), "hill body CRC-32")
    // 150-byte chunks: a 159-byte plaintext write limit minus the 9-byte header.
    let frames = DeviceProtocol.transferFrames(body: body, routeToken: 0x1234_5678, revision: 3,
                                               transferID: 0x0102, maximumWriteLength: 159)!
    for (index, frame) in frames.enumerated() {
        expect(frame == bytes["hill_frame_\(index)"], "hill frame \(index)")
    }
    expect(bytes["hill_frame_\(frames.count)"] == nil, "no extra hill frames")
    let gaps = fixtureProfile(cases["missing-data"]!)
    expect(DeviceProtocol.encodeBody(gaps, routeToken: 0xCAFE_F00D, revision: 1,
                                     points: DeviceProtocol.displayPoints(gaps)) == bytes["gaps_body"], "gap body")
    let long = fixtureProfile(cases["long-route-spacing"]!)
    expect(DeviceProtocol.encodeBody(long, routeToken: 1, revision: 65_535,
                                     points: DeviceProtocol.displayPoints(long)) == bytes["long_body"], "long body")
    let query = cases["ordinary-hill"]!.expected.queries[1]
    let position = RouteElevationPositionV1(
        distanceMeters: query.distanceM, elevationMeters: query.elevationM,
        elevationEstimated: query.elevationEstimated, gradePercent: query.gradePercent,
        gradeEstimated: query.gradeEstimated, ascentRemainingMeters: query.ascentRemainingM,
        ascentRemainingIsLowerBound: query.ascentRemainingLowerBound
    )
    expect(DeviceProtocol.progressFrame(routeToken: 0x1234_5678, revision: 3, sequence: 7, progressMeters: 1235,
                                        position: position, onRoute: true) == bytes["hill_progress"], "progress")
    expect(DeviceProtocol.progressFrame(routeToken: 0x1234_5678, revision: 3, sequence: 8, progressMeters: 1235,
                                        position: nil, onRoute: false) == bytes["hill_progress_off_route"],
           "off-route progress")
    expect(DeviceProtocol.stateFrame(routeToken: 0x1234_5678, revision: 3, state: .loading, reason: .unspecified) ==
           bytes["state_loading"], "loading state")
    expect(DeviceProtocol.stateFrame(routeToken: 0x1234_5678, revision: 4, state: .unavailable,
                                     reason: .sourceNotPermitted) == bytes["state_unavailable_source"],
           "unavailable state")
    expect(DeviceProtocol.stateFrame(routeToken: 0, revision: 0, state: .cleared, reason: .unspecified) ==
           bytes["state_cleared"], "cleared state")
    let applied = DeviceProtocol.decodeAcknowledgement(bytes["ack_commit_applied"]!)
    expect(applied == .init(op: DeviceProtocol.Op.commit.rawValue, result: .applied, routeToken: 0x1234_5678,
                            revision: 3, transferID: 0x0102), "applied acknowledgement")
    expect(DeviceProtocol.decodeAcknowledgement(bytes["ack_commit_crc"]!)?.result == .crcMismatch, "CRC ack")
    expect(DeviceProtocol.decodeAcknowledgement(Data(bytes["ack_commit_applied"]!.dropLast())) == nil,
           "short acknowledgement rejected")
    expect(DeviceProtocol.transferFrames(body: body, routeToken: 1, revision: 1, transferID: 1,
                                         maximumWriteLength: 40) == nil, "tiny links cannot carry a profile")
    expect(DeviceProtocol.encodeBody(hill, routeToken: 0, revision: 1, points: DeviceProtocol.displayPoints(hill)) == nil,
           "zero token rejected")
}

private func gpxData(_ points: [(latitude: Double, longitude: Double, elevation: String?)]) -> Data {
    var text = "<?xml version=\"1.0\"?><gpx version=\"1.1\" creator=\"tests\" xmlns=\"http://www.topografix.com/GPX/1/1\">"
    text += "<trk><name>Hill</name><trkseg>"
    for point in points {
        text += "<trkpt lat=\"\(point.latitude)\" lon=\"\(point.longitude)\">"
        if let elevation = point.elevation { text += "<ele>\(elevation)</ele>" }
        text += "</trkpt>"
    }
    text += "</trkseg></trk></gpx>"
    return Data(text.utf8)
}

private func hillPoints(count: Int = 80, base: Double = 420) -> [(latitude: Double, longitude: Double, elevation: String?)] {
    (0..<count).map { index in
        let elevation = base + 120 * sin(Double(index) / Double(count - 1) * .pi)
        return (47.0 + Double(index) * 0.0004, 8.0 + Double(index) * 0.0001, String(format: "%.2f", elevation))
    }
}

private func testGPXImportAndTrust() {
    let imported = try! GPXRouteImporterV1.importRoute(
        data: gpxData(hillPoints()), fallbackName: "Hill", source: .local(createdAt: Date(timeIntervalSince1970: 0))
    )
    let heights = imported.vertexElevations!
    expect(heights.count == imported.archive.route.points.count, "one height per vertex")
    expect(heights.allSatisfy { value in value.map { ($0 * 10).rounded() == $0 * 10 } ?? false },
           "heights are decimetre-quantized")

    var withGaps = hillPoints(count: 6)
    withGaps[2].elevation = "not-a-number"
    withGaps[3].elevation = nil
    let gaps = try! GPXRouteImporterV1.importRoute(data: gpxData(withGaps), fallbackName: "Gaps",
                                                   source: .local(createdAt: Date()))
    expect(gaps.vertexElevations?[2] == nil && gaps.vertexElevations?[3] == nil &&
           gaps.vertexElevations?[0] != nil, "unparseable and missing <ele> stay unknown")

    let flat = hillPoints(count: 6).map { (latitude: $0.latitude, longitude: $0.longitude, elevation: String?.none) }
    let none = try! GPXRouteImporterV1.importRoute(data: gpxData(flat), fallbackName: "None",
                                                   source: .local(createdAt: Date()))
    expect(none.vertexElevations == nil, "a file without <ele> carries no heights")

    let duplicate = try! GPXRouteImporterV1.importRoute(data: gpxData([
        (47.0, 8.0, "10"), (47.0, 8.0, "20"), (47.001, 8.0, nil), (47.001, 8.0, "30"), (47.002, 8.0, "31"),
    ]), fallbackName: "Duplicate", source: .local(createdAt: Date()))
    expect(duplicate.vertexElevations == [10, 30, 31], "duplicates keep the first recorded height")

    let geometry = try! RouteElevationProcessorV1.geometry(points: imported.archive.route.points)
    guard case .trusted = RouteElevationGPXTrustV1.evaluate(vertexElevations: heights,
                                                            cumulativeMeters: geometry.cumulativeMeters) else {
        fatalError("FAILED: a smooth GPX hill is trusted")
    }
    let zeros = [Double?](repeating: 0, count: geometry.pointCount)
    expect(RouteElevationGPXTrustV1.evaluate(vertexElevations: zeros, cumulativeMeters: geometry.cumulativeMeters) ==
           .untrusted(reason: "zero-filled-elevation"), "zero-filled heights are not trusted")
    let sparse = heights.enumerated().map { $0.offset % 3 == 0 ? $0.element : nil }
    expect(RouteElevationGPXTrustV1.evaluate(vertexElevations: sparse, cumulativeMeters: geometry.cumulativeMeters) ==
           .untrusted(reason: "missing-elevation"), "sparse heights are not trusted")
    let noisy = heights.enumerated().map { $0.offset % 4 == 1 ? $0.element.map { $0 + 80 } : $0.element }
    expect(RouteElevationGPXTrustV1.evaluate(vertexElevations: noisy, cumulativeMeters: geometry.cumulativeMeters) ==
           .untrusted(reason: "noisy-elevation"), "spiky heights are not trusted")

    let prepared = RouteElevationPreparationV1.prepare(
        points: imported.archive.route.points, maximumPoints: 50_000, gpxVertexElevations: heights
    )!
    let local = prepared.localProfile!
    expect(local.source.kind == "gpx" && local.source.qualification == "user-supplied", "GPX source is named")
    expect(local.quality.status == Contract.qualityComplete, "trusted GPX makes a complete profile")
    expect(close(local.statistics.maximumElevationM, 540, 2.5), "GPX peak is preserved, not replaced")
}

private func withProvider(_ route: NavigationRouteV1, _ provider: RouteProviderMetadataV1) -> NavigationRouteV1 {
    NavigationRouteV1(
        id: route.id, revision: route.revision, provider: provider, sourceReference: nil,
        localeIdentifier: route.localeIdentifier, transportType: route.transportType, source: route.source,
        destination: route.destination, bounds: route.bounds, distanceMeters: route.distanceMeters,
        expectedTravelTimeSeconds: route.expectedTravelTimeSeconds, name: route.name, points: route.points,
        steps: route.steps, normalizationVersion: route.normalizationVersion
    )
}

private func makeRoute(provider: RouteProviderMetadataV1, count: Int = 60,
                       latitude: Double = 47.0, longitude: Double = 8.0) -> NavigationRouteV1 {
    let points = (0..<count).map {
        (latitude: latitude + Double($0) * 0.0004, longitude: longitude + Double($0) * 0.0001, elevation: String?.none)
    }
    let route = try! GPXRouteImporterV1.importRoute(data: gpxData(points), fallbackName: "Route",
                                                    source: .local(createdAt: Date())).archive.route
    return withProvider(route, provider)
}

private func testPolicy() {
    expect(RouteProviderPolicyV1.allowsRouteElevationService(RouteProviderPolicyV1.importedGPX),
           "imported GPX geometry may use the service")
    expect(RouteProviderPolicyV1.routeElevationServiceSource(RouteProviderPolicyV1.importedGPX) == "gpx",
           "imported GPX retains its provenance")
    for metadata in [RouteProviderPolicyV1.mapKit, RouteProviderPolicyV1.mapKitSavedOnPhone] {
        expect(RouteProviderPolicyV1.allowsRouteElevationService(metadata) &&
               RouteProviderPolicyV1.routeElevationServiceSource(metadata) == "mapkit",
               "active and saved Apple Maps routes may request terrain heights")
    }
    for metadata in [RouteProviderPolicyV1.strava,
                     RouteProviderMetadataV1(providerID: "unknown", attribution: "Unknown", storageScope: .durable),
                     RouteProviderMetadataV1(providerID: "apple.mapkit", attribution: "Unknown", storageScope: .durable)] {
        expect(!RouteProviderPolicyV1.allowsRouteElevationService(metadata) &&
               RouteProviderPolicyV1.routeElevationServiceSource(metadata) == nil,
               "unapproved or inconsistent providers cannot request terrain heights")
    }
}

private func testSidecarStore() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("route-elevation-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RouteElevationSidecarStoreV1(directory: directory)
    let binding = RouteElevationArchiveBindingV1(routeID: UUID(), revision: 2, contentHash: "abc")
    let sidecar = RouteElevationSidecarV1(binding: binding, geometryDigest: "digest",
                                          gpxVertexElevations: [12.34, nil, -3.25], serviceProfile: nil)
    try! store.save(sidecar)
    let loaded = store.load(binding)
    expect(loaded?.gpxVertexElevations == [12.3, nil, -3.3], "sidecars keep decimetre GPX heights")
    expect(store.load(.init(routeID: binding.routeID, revision: 3, contentHash: "abc")) == nil,
           "a sidecar never serves another revision")
    expect(store.load(.init(routeID: binding.routeID, revision: 2, contentHash: "other")) == nil,
           "a sidecar never serves other content")
    let raw = try! String(contentsOf: directory.appendingPathComponent(
        binding.routeID.uuidString.lowercased() + ".json"), encoding: .utf8)
    expect(!raw.contains("latitude") && !raw.contains("coordinates"), "sidecars hold no coordinates")
    let other = RouteElevationArchiveBindingV1(routeID: UUID(), revision: 1, contentHash: "x")
    try! store.save(RouteElevationSidecarV1(binding: other, geometryDigest: "d", gpxVertexElevations: nil,
                                            serviceProfile: nil))
    store.prune(keeping: [binding])
    expect(store.load(binding) != nil && store.load(other) == nil, "pruning removes sidecars of gone archives")
    store.remove(routeID: binding.routeID)
    expect(store.load(binding) == nil, "deleting a route deletes its sidecar")
}

private func testResponseDecoder(_ fixture: ProcessingFixture) {
    let data = try! Data(contentsOf: fixtureDirectory.appendingPathComponent("service-response-v1.json"))
    let response = try! RouteElevationResponseDecoderV1.decode(
        statusCode: 200, cacheControl: "private, no-store", contentType: "application/json; charset=utf-8",
        retryAfter: nil, body: data
    )
    let hill = fixture.cases.first { $0.name == "ordinary-hill" }!
    let geometry = try! RouteElevationProcessorV1.geometry(latitudeE6: hill.latitudeE6, longitudeE6: hill.longitudeE6)
    guard case .ready(let profile) = RouteElevationPreparationV1.state(for: response, geometry: geometry) else {
        fatalError("FAILED: the backend's ready answer decodes and validates")
    }
    expect(profile.source.kind == "hosted-terrain" && profile.source.verticalDatum == nil,
           "hosted terrain keeps an honest unknown datum")
    expect(profile.source.attribution.contains("Powered by Geoapify (https://www.geoapify.com/)"),
           "Geoapify attribution travels with the profile")
    expect(response.attempts.first?.coverage == 1.0, "attempt coverage decodes")
    let other = try! RouteElevationProcessorV1.geometry(latitudeE6: hill.latitudeE6.reversed(),
                                                        longitudeE6: hill.longitudeE6.reversed())
    expect(RouteElevationPreparationV1.state(for: response, geometry: other) == .unavailable(.serviceUnavailable),
           "a profile for different geometry is rejected")

    func decodeError(status: Int, cacheControl: String? = "private, no-store", retryAfter: String? = nil,
                     body: Data = data) -> RouteElevationClientError? {
        do {
            _ = try RouteElevationResponseDecoderV1.decode(statusCode: status, cacheControl: cacheControl,
                                                           contentType: "application/json",
                                                           retryAfter: retryAfter, body: body)
            return nil
        } catch {
            return error as? RouteElevationClientError
        }
    }
    expect(decodeError(status: 200, cacheControl: nil) == .invalidResponse, "a cacheable answer is rejected")
    expect(decodeError(status: 429, retryAfter: "120") == .rateLimited(retryAfterSeconds: 120), "rate limit")
    expect(decodeError(status: 503, retryAfter: "5") == .unavailable(retryAfterSeconds: 5), "busy service")
    expect(decodeError(status: 400, body: Data(#"{"detail":{"code":"route_elevation_invalid_request","message":"no"}}"#.utf8)) ==
           .rejected(code: "route_elevation_invalid_request"), "rejected request code")
    let missingProfile = Data(#"{"schema":"bicino-route-elevation-response-v1","status":"ready","profile":null,"attempts":[],"retryAfterSeconds":null}"#.utf8)
    expect(decodeError(status: 200, body: missingProfile) == .invalidResponse, "ready requires a profile")
    let quota = Data(#"{"schema":"bicino-route-elevation-response-v1","status":"unavailable","profile":null,"attempts":[{"provider":"geoapify","status":"failed","reason":"quota-exhausted"}],"retryAfterSeconds":3600}"#.utf8)
    let quotaResponse = try! RouteElevationResponseDecoderV1.decode(
        statusCode: 200, cacheControl: "private, no-store", contentType: "application/json", retryAfter: nil, body: quota
    )
    expect(RouteElevationPreparationV1.state(for: quotaResponse, geometry: geometry) ==
           .unavailable(.rateLimited(retryAfterSeconds: 3600)), "exhausted credits are reported as paused")
    let thin = Data(#"{"schema":"bicino-route-elevation-response-v1","status":"unavailable","profile":null,"attempts":[{"provider":"geoapify","status":"unavailable","coverage":0.02,"creditsUsed":1}],"retryAfterSeconds":null}"#.utf8)
    let thinResponse = try! RouteElevationResponseDecoderV1.decode(
        statusCode: 200, cacheControl: "private, no-store", contentType: "application/json", retryAfter: nil, body: thin
    )
    expect(RouteElevationPreparationV1.state(for: thinResponse, geometry: geometry) == .unavailable(.noCoverage),
           "answered but uncovered routes say so")
    expect(RouteElevationClientError.classify(URLError(.notConnectedToInternet)) == .offline, "offline mapping")
    expect(RouteElevationClientError.classify(URLError(.timedOut)) == .unavailable(retryAfterSeconds: nil),
           "timeouts are service failures")
}

private func testRequestUsesWGS84GeoJSONOrder() {
    // Shanghai: the map shows GCJ-02, but routes and requests stay WGS-84.
    let route = makeRoute(provider: RouteProviderPolicyV1.importedGPX, count: 8, latitude: 31.23, longitude: 121.47)
    let geometry = try! RouteElevationProcessorV1.geometry(points: route.points)
    let request = RouteElevationPreparationV1.request(for: geometry, requestID: UUID(), routeSource: "gpx")
    expect(request.geometry.coordinatesE6.first == [RouteElevationProcessorV1.scaled(route.points[0].longitude),
                                                    RouteElevationProcessorV1.scaled(route.points[0].latitude)],
           "coordinates are [lonE6, latE6] of the unshifted WGS-84 route")
    expect(request.geometry.digest == geometry.digest && request.geometry.crs == "EPSG:4326", "digest and CRS")
    expect(request.routeSource == "gpx" && request.travelMode == "cycling", "route source and mode")
    expect(request.requestId == request.requestId.lowercased() && UUID(uuidString: request.requestId) != nil,
           "lowercase UUID request ID")
}

@MainActor
private final class FakeFetcher: RouteElevationProfileFetching {
    var requests: [RouteElevationServiceRequestV1] = []
    var failure: RouteElevationClientError?

    func fetchProfile(_ request: RouteElevationServiceRequestV1) async throws -> RouteElevationServiceResponseV1 {
        requests.append(request)
        for _ in 0..<5 { await Task.yield() }
        if let failure { throw failure }
        let geometry = try RouteElevationProcessorV1.geometry(
            latitudeE6: request.geometry.coordinatesE6.map { $0[1] },
            longitudeE6: request.geometry.coordinatesE6.map { $0[0] }
        )
        let plan = RouteElevationProcessorV1.plan(length: geometry.lengthMeters)
        let raw = plan.distancesMeters.map { Optional(300 + $0 * 0.02) }
        let profile = RouteElevationProcessorV1.process(geometry: geometry, plan: plan, rawElevations: raw,
                                                        source: fixtureSource)!
        return RouteElevationServiceResponseV1(schema: Contract.responseSchema, status: "ready", profile: profile,
                                               attempts: [], retryAfterSeconds: nil)
    }
}

@MainActor
private final class FakeSidecars: RouteElevationSidecarProviding {
    var sidecars: [RouteElevationArchiveBindingV1: RouteElevationSidecarV1] = [:]
    var stored: [RouteElevationArchiveBindingV1] = []

    func elevationSidecar(for binding: RouteElevationArchiveBindingV1) -> RouteElevationSidecarV1? {
        sidecars[binding]
    }

    func storeElevationProfile(_ profile: RouteElevationProfileV1, for binding: RouteElevationArchiveBindingV1) {
        stored.append(binding)
        sidecars[binding] = (sidecars[binding] ?? RouteElevationSidecarV1(
            binding: binding, geometryDigest: profile.geometry.digest, gpxVertexElevations: nil, serviceProfile: nil
        )).replacingServiceProfile(profile)
    }

    func elevationSubject(for binding: RouteElevationArchiveBindingV1) -> RouteElevationSubjectV1? { nil }
}

@MainActor
private func testMapKitService() async {
    for provider in [RouteProviderPolicyV1.mapKit, RouteProviderPolicyV1.mapKitSavedOnPhone] {
        let fetcher = FakeFetcher()
        let sidecars = FakeSidecars()
        let service = RouteElevationService(fetcher: fetcher, sidecars: sidecars)
        let route = makeRoute(provider: provider)
        let binding = RouteElevationArchiveBindingV1(routeID: route.id, revision: route.revision, contentHash: "mapkit")
        let subject = RouteElevationSubjectV1(
            route: route, binding: provider == RouteProviderPolicyV1.mapKitSavedOnPhone ? binding : nil
        )
        guard case .ready(let profile) = await service.resolve(subject) else {
            fatalError("FAILED: an Apple Maps route without GPX heights resolves through the service")
        }
        expect(fetcher.requests.count == 1 && fetcher.requests[0].routeSource == "mapkit",
               "Apple Maps geometry reaches the service with its original provenance")
        let geometry = try! RouteElevationProcessorV1.geometry(points: route.points)
        expect(profile.geometry.digest == geometry.digest && fetcher.requests[0].geometry.digest == geometry.digest,
               "the profile is bound to the selected Apple Maps geometry")
        if provider == RouteProviderPolicyV1.mapKitSavedOnPhone {
            expect(sidecars.stored == [binding], "a saved Apple Maps route keeps its elevation profile")
            let offline = RouteElevationService(fetcher: nil, sidecars: sidecars)
            expect(await offline.resolve(subject) == .ready(profile), "saved Apple Maps elevation works offline")
        } else {
            expect(sidecars.stored.isEmpty, "active-only Apple Maps routes do not create a sidecar")
        }
    }
}

@MainActor
private func testService() async {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let fetcher = FakeFetcher()
    let sidecars = FakeSidecars()
    let service = RouteElevationService(fetcher: fetcher, sidecars: sidecars, now: { clock })

    let strava = RouteElevationSubjectV1(route: makeRoute(provider: RouteProviderPolicyV1.strava))
    expect(await service.resolve(strava) == .unavailable(.sourceNotPermitted), "Strava without heights stays local")
    expect(fetcher.requests.isEmpty, "ineligible sources never reach the service")

    let imported = try! GPXRouteImporterV1.importRoute(data: gpxData(hillPoints()), fallbackName: "Hill",
                                                       source: .local(createdAt: Date()))
    let draft = RouteElevationSubjectV1(route: imported.archive.route, gpxVertexElevations: imported.vertexElevations)
    guard case .ready(let local) = await service.resolve(draft), local.source.kind == "gpx" else {
        fatalError("FAILED: trusted GPX heights become the profile")
    }
    expect(fetcher.requests.isEmpty, "trusted GPX heights never call the service")
    let stravaHeights = RouteElevationSubjectV1(route: withProvider(imported.archive.route, RouteProviderPolicyV1.strava),
                                                gpxVertexElevations: imported.vertexElevations)
    guard case .ready(let stravaLocal) = await service.resolve(stravaHeights), stravaLocal.source.kind == "gpx" else {
        fatalError("FAILED: a Strava route's own GPX heights stay usable on the phone")
    }
    let misaligned = RouteElevationSubjectV1(route: makeRoute(provider: RouteProviderPolicyV1.strava, count: 30),
                                             gpxVertexElevations: imported.vertexElevations)
    expect(await service.resolve(misaligned) == .unavailable(.sourceNotPermitted),
           "heights that do not align with the geometry are ignored")
    expect(fetcher.requests.isEmpty, "local sources never call the service")

    let route = makeRoute(provider: RouteProviderPolicyV1.importedGPX)
    let binding = RouteElevationArchiveBindingV1(routeID: route.id, revision: route.revision, contentHash: "hash")
    let saved = RouteElevationSubjectV1(route: route, binding: binding)
    async let first = service.resolve(saved)
    async let second = service.resolve(saved)
    let (one, two) = await (first, second)
    guard case .ready(let remote) = one, one == two else { fatalError("FAILED: the service profile resolves") }
    expect(fetcher.requests.count == 1, "concurrent requests share one provider call")
    expect(sidecars.stored.contains(binding), "a saved route keeps its service profile")
    expect(service.cachedState(for: saved) == .ready(remote), "the profile is cached for the subject")
    expect(await service.resolve(saved) == .ready(remote) && fetcher.requests.count == 1, "memory cache")

    let fresh = RouteElevationService(fetcher: fetcher, sidecars: sidecars, now: { clock })
    expect(await fresh.resolve(saved) == .ready(remote) && fetcher.requests.count == 1,
           "the saved profile works offline after a restart")

    let unsaved = RouteElevationSubjectV1(route: makeRoute(provider: RouteProviderPolicyV1.importedGPX, count: 70))
    fetcher.failure = .offline
    expect(await service.resolve(unsaved) == .unavailable(.offline), "offline state")
    expect(await service.resolve(unsaved) == .unavailable(.offline) && fetcher.requests.count == 2,
           "a recent failure is not retried automatically")
    fetcher.failure = nil
    guard case .ready = await service.resolve(unsaved, retry: true) else {
        fatalError("FAILED: an explicit retry asks again")
    }
    expect(fetcher.requests.count == 3, "retry reached the service")

    let limited = RouteElevationSubjectV1(route: makeRoute(provider: RouteProviderPolicyV1.importedGPX, count: 75))
    fetcher.failure = .rateLimited(retryAfterSeconds: 600)
    expect(await service.resolve(limited) == .unavailable(.rateLimited(retryAfterSeconds: 600)), "rate limited")
    fetcher.failure = nil
    expect(await service.resolve(limited, retry: true) == .unavailable(.rateLimited(retryAfterSeconds: 600)) &&
           fetcher.requests.count == 4, "Retry-After is honored even on an explicit retry")
    clock = clock.addingTimeInterval(601)
    guard case .ready = await service.resolve(limited) else { fatalError("FAILED: allowed after Retry-After") }

    expect(RouteElevationPreparationV1.automaticRetryDelay(for: .offline)! >
           RouteElevationPreparationV1.retryDelay(for: .unavailable(.offline), error: .offline)! &&
           RouteElevationPreparationV1.automaticRetryDelay(for: .serviceUnavailable)! >
           RouteElevationPreparationV1.retryDelay(for: .unavailable(.serviceUnavailable),
                                                  error: .unavailable(retryAfterSeconds: nil))!,
           "navigation retries only after the failure memo expires")
    expect(RouteElevationPreparationV1.automaticRetryDelay(for: .noCoverage) == nil &&
           RouteElevationPreparationV1.automaticRetryDelay(for: .sourceNotPermitted) == nil,
           "permanent states are not retried automatically")

    let disabled = RouteElevationService(fetcher: nil, sidecars: nil)
    expect(await disabled.resolve(RouteElevationSubjectV1(route: makeRoute(provider: RouteProviderPolicyV1.importedGPX, count: 64))) ==
           .unavailable(.serviceUnavailable), "no client means service unavailable")
}

private func testPlannerHappyPath(_ hill: RouteElevationProfileV1) {
    var tokens: [UInt32] = [0xA1, 0xB2, 0xC3, 0xD4]
    var planner = Planner(makeToken: { tokens.removeFirst() })
    var sent: [(frames: [Data], coalescible: Bool)] = []
    func tick(_ now: TimeInterval, accept: Bool = true) {
        planner.tick(now: now) { frames, coalescible in
            if accept { sent.append((frames, coalescible)) }
            return accept
        }
    }
    let key = Planner.RouteKey(navigationGeneration: 1, routeID: UUID(), revision: 1)
    planner.connect(maximumWriteLength: 159)
    planner.update(route: key, content: .loading)
    tick(0)
    expect(sent.count == 1 && sent[0].frames == [DeviceProtocol.stateFrame(
        routeToken: 0xA1, revision: 1, state: .loading, reason: .unspecified)], "loading state first")
    expect(planner.status == .showingState, "device shows loading")

    planner.update(route: key, content: .profile(hill))
    tick(1, accept: false)
    expect(planner.revision == 1 && sent.count == 1, "a rejected batch is retried without a new revision")
    tick(1)
    let body = DeviceProtocol.encodeBody(hill, routeToken: 0xA1, revision: 2, points: DeviceProtocol.displayPoints(hill))!
    expect(sent.count == 2 && sent[1].frames == DeviceProtocol.transferFrames(
        body: body, routeToken: 0xA1, revision: 2, transferID: 1, maximumWriteLength: 159)! &&
        !sent[1].coalescible, "profile travels as one atomic batch")
    expect(planner.status == .sending, "awaiting COMMIT acknowledgement")

    let position = hill.position(atDistance: 1_234.5)
    planner.update(progress: .init(meters: 1_234.5, position: position, onRoute: true))
    tick(2)
    expect(sent.count == 2, "no progress before the device applies the profile")
    planner.receive(.init(op: DeviceProtocol.Op.commit.rawValue, result: .applied, routeToken: 0xA1,
                          revision: 2, transferID: 9))
    expect(planner.status == .sending, "an acknowledgement for another transfer is ignored")
    planner.receive(.init(op: DeviceProtocol.Op.begin.rawValue, result: .applied, routeToken: 0xA1,
                          revision: 2, transferID: 1))
    expect(planner.status == .sending, "BEGIN acknowledgements do not complete a transfer")
    planner.receive(.init(op: DeviceProtocol.Op.commit.rawValue, result: .applied, routeToken: 0xA1,
                          revision: 2, transferID: 1))
    expect(planner.status == .delivered && planner.deliveredRevision == 2, "applied")
    tick(3)
    expect(sent.count == 3 && sent[2].coalescible && sent[2].frames == [DeviceProtocol.progressFrame(
        routeToken: 0xA1, revision: 2, sequence: 1, progressMeters: 1_235, position: position, onRoute: true)],
        "progress follows the delivered revision")
    tick(3.5)
    expect(sent.count == 3, "unchanged progress is not resent")
    planner.update(progress: .init(meters: 1_300, position: hill.position(atDistance: 1_300), onRoute: true))
    tick(3.9)
    expect(sent.count == 3, "progress is limited to 1 Hz")
    tick(4.1)
    expect(sent.count == 4, "changed progress after one second")
    tick(19.2)
    expect(sent.count == 5, "unchanged progress is refreshed every 15 s")
    planner.update(progress: .init(meters: 1_300, position: nil, onRoute: false))
    tick(20.3)
    expect(sent.count == 6 && sent[5].frames[0][6 + 12] & 0x01 == 0, "off-route progress clears the on-route bit")

    let next = Planner.RouteKey(navigationGeneration: 2, routeID: UUID(), revision: 1)
    planner.update(route: next, content: .unavailable(.sourceNotPermitted))
    tick(21)
    expect(sent.last?.frames == [DeviceProtocol.stateFrame(routeToken: 0xB2, revision: 1, state: .unavailable,
                                                           reason: .sourceNotPermitted)],
           "a new route gets a new token and starts at revision 1")
    planner.update(route: nil, content: nil)
    tick(22)
    expect(sent.last?.frames == [DeviceProtocol.stateFrame(routeToken: 0, revision: 0, state: .cleared,
                                                           reason: .unspecified)], "stopping clears the device")
    let count = sent.count
    tick(23)
    expect(sent.count == count && planner.status == .idle, "nothing more after clearing")

    planner.update(route: key, content: .profile(hill))
    tick(24)
    expect(sent.last?.frames.first.map { Array($0[6..<10]) } == [0xC3, 0, 0, 0], "route token")
    planner.disconnect()
    planner.connect(maximumWriteLength: 159)
    tick(26)
    expect(sent.last?.frames.first.map { Array($0[6..<10]) } == [0xD4, 0, 0, 0] &&
           sent.last?.frames.first.map { Array($0[10..<12]) } == [1, 0],
           "a new BLE session resends at revision 1 with a fresh token")
}

private func testPlannerRetries(_ hill: RouteElevationProfileV1) {
    var planner = Planner(makeToken: { 0x55 })
    var sent: [[Data]] = []
    func tick(_ now: TimeInterval) {
        planner.tick(now: now) { frames, _ in
            sent.append(frames)
            return true
        }
    }
    planner.connect(maximumWriteLength: 120)
    planner.update(route: .init(navigationGeneration: 7, routeID: UUID(), revision: 3), content: .profile(hill))
    tick(0)
    tick(5.9)
    expect(sent.count == 1, "waits for the acknowledgement")
    tick(6.1)
    expect(sent.count == 2 && sent[1].first?[12] == 2, "timeout retries with a new transfer ID")
    planner.receive(.init(op: DeviceProtocol.Op.commit.rawValue, result: .crcMismatch, routeToken: 0x55,
                          revision: 1, transferID: 2))
    tick(6.2)
    expect(sent.count == 3 && sent[2].first?[12] == 3, "a CRC failure retries immediately")
    tick(12.3)
    tick(12.4)
    expect(sent.last == [DeviceProtocol.stateFrame(routeToken: 0x55, revision: 2, state: .failed,
                                                   reason: .transferFailed)],
           "after three attempts the device is told the transfer failed")
    expect(planner.status == .failed, "failed status")
    planner.receive(.init(op: DeviceProtocol.Op.commit.rawValue, result: .applied, routeToken: 0x55,
                          revision: 1, transferID: 1))
    expect(planner.status == .failed, "a late acknowledgement cannot resurrect a failed transfer")

    var unsupported = Planner(makeToken: { 0x66 })
    unsupported.connect(maximumWriteLength: 120)
    unsupported.update(route: .init(navigationGeneration: 1, routeID: UUID(), revision: 1), content: .profile(hill))
    unsupported.tick(now: 0) { _, _ in true }
    unsupported.receive(.init(op: DeviceProtocol.Op.state.rawValue, result: .unsupported, routeToken: 0,
                              revision: 0, transferID: 0))
    var after = 0
    unsupported.tick(now: 100) { _, _ in after += 1; return true }
    expect(unsupported.status == .failed && after == 0, "an unsupported frame version stops delivery")
    expect(Planner.revision(after: UInt16.max) == 1, "revisions skip zero when wrapping")
}

@main
enum RouteElevationTestRunner {
    @MainActor
    static func main() async {
        let fixture = loadProcessingFixture()
        testProcessingParity(fixture)
        testDisplayAndQueries(fixture)
        testTransferBytes(fixture)
        testGPXImportAndTrust()
        testPolicy()
        testSidecarStore()
        testResponseDecoder(fixture)
        testRequestUsesWGS84GeoJSONOrder()
        await testMapKitService()
        await testService()
        let hill = fixtureProfile(fixture.cases.first { $0.name == "ordinary-hill" }!)
        testPlannerHappyPath(hill)
        testPlannerRetries(hill)
        print("Route elevation tests passed")
    }
}
