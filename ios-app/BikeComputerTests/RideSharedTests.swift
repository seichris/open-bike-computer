import Foundation

@main
enum RideSharedTests {
    static func main() throws {
        try testArchiveIntegrityAndRetention()
        try testRouteValidationBoundaries()
        try testRuntimeProgressDeviationAndReplacement()
        try testRouteFileStoreAndSyncContract()
        try testWatchControllerContract()
        try testWatchDirectBLEContract()
        try testFavoriteSyncPolicyAndCoordinateNormalization()
        try testGPXImport()
        print("RideSharedTests passed")
    }

    private static func testGPXImport() throws {
        let routeGPX = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Bicino test">
          <rte>
            <name>Morning Loop</name>
            <rtept lat="1.0000" lon="103.0000"><name>Start</name></rtept>
            <rtept lat="1.0005" lon="103.0005"><name>Checkpoint</name></rtept>
            <rtept lat="1.0010" lon="103.0010"><name>Cafe</name></rtept>
          </rte>
        </gpx>
        """.utf8)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let archive = try GPXRouteImporterV1.archive(
            data: routeGPX,
            fallbackName: "fallback.gpx",
            routeID: UUID(
                uuidString: "bbbbbbbb-1111-2222-3333-cccccccccccc"
            )!,
            createdAt: createdAt,
            localeIdentifier: "en_US"
        )
        expect(
            archive.route.provider == RouteProviderPolicyV1.importedGPX &&
                archive.route.name == "Morning Loop" &&
                archive.route.source.label == "Start" &&
                archive.route.destination.label == "Cafe" &&
                archive.route.steps.last?.maneuver == .arrive,
            "a user-owned GPX route becomes a durable validated archive"
        )
        try expect(
            try NavigationRouteArchiveV1.decode(
                archive.encoded(
                    purpose: .offlineNavigation,
                    now: createdAt
                ),
                purpose: .offlineNavigation,
                now: createdAt
            ) == archive,
            "the imported GPX archive is ready for exact Watch transfer"
        )

        let trackGPX = Data("""
        <gpx version="1.1" creator="Bicino test">
          <trk><name>Recorded ride</name>
            <trkseg>
              <trkpt lat="2" lon="104"/><trkpt lat="2" lon="104"/>
            </trkseg>
            <trkseg>
              <trkpt lat="1" lon="103"/>
              <trkpt lat="1.001" lon="103.001"/>
              <trkpt lat="1.002" lon="103.002"/>
            </trkseg>
          </trk>
        </gpx>
        """.utf8)
        let track = try GPXRouteImporterV1.archive(
            data: trackGPX,
            fallbackName: "ride.gpx",
            createdAt: createdAt
        )
        expect(
            track.route.points.count == 3 &&
                track.route.name == "Recorded ride" &&
                track.route.steps.count == 2,
            "the longest usable track segment is selected without joining gaps"
        )

        expectThrows(
            GPXRouteImporterError.invalidCoordinate,
            "invalid GPX coordinates fail closed"
        ) {
            _ = try GPXRouteImporterV1.archive(
                data: Data("<gpx><rte><rtept lat=\"91\" lon=\"1\"/></rte></gpx>".utf8),
                fallbackName: "invalid.gpx",
                createdAt: createdAt
            )
        }
        expectThrows(
            GPXRouteImporterError.noUsableRoute,
            "metadata-only GPX cannot enter the route library"
        ) {
            _ = try GPXRouteImporterV1.archive(
                data: Data("<gpx><metadata><name>Empty</name></metadata></gpx>".utf8),
                fallbackName: "empty.gpx",
                createdAt: createdAt
            )
        }
        expectThrows(
            GPXRouteImporterError.malformedXML,
            "GPX entity declarations are rejected before expansion"
        ) {
            _ = try GPXRouteImporterV1.archive(
                data: Data("""
                <!DOCTYPE gpx [<!ENTITY repeated "route">]>
                <gpx><rte><name>&repeated;</name>
                <rtept lat="1" lon="103"/>
                <rtept lat="1.001" lon="103.001"/>
                </rte></gpx>
                """.utf8),
                fallbackName: "entity.gpx",
                createdAt: createdAt
            )
        }
        expectThrows(
            GPXRouteImporterError.fileTooLarge,
            "oversized GPX input is rejected before XML parsing"
        ) {
            _ = try GPXRouteImporterV1.archive(
                data: Data(
                    repeating: 0,
                    count: GPXRouteImporterV1.maximumInputBytes + 1
                ),
                fallbackName: "large.gpx",
                createdAt: createdAt
            )
        }
    }

    private static func testFavoriteSyncPolicyAndCoordinateNormalization() throws {
        let favorite = SyncedCoordinateFavoriteV1(
            id: UUID(
                uuidString: "12345678-1234-1234-1234-123456789abc"
            )!,
            name: "  Home  ",
            coordinate: RouteCoordinateV1(
                latitude: 31.2304,
                longitude: 121.4737
            )
        )
        let envelope = CoordinateFavoritesEnvelopeV1(
            revision: 7,
            favorites: [favorite]
        )
        let decoded = try CoordinateFavoritesEnvelopeV1.decode(
            envelope.encoded()
        )
        expect(
            decoded.revision == 7 && decoded.favorites[0].name == "Home",
            "favorite sync is versioned, bounded, and canonical"
        )
        expectThrows(
            SyncedFavoriteContractError.duplicateFavorite,
            "duplicate favorite identities are rejected"
        ) {
            _ = try CoordinateFavoritesEnvelopeV1(
                revision: 8,
                favorites: [favorite, favorite]
            ).validated()
        }

        let wgs84 = RouteCoordinateV1(
            latitude: 31.2304,
            longitude: 121.4737
        )
        let mapKit = RouteCoordinateNormalizationV1.wgs84ToMapKit(wgs84)
        let roundTrip = RouteCoordinateNormalizationV1.mapKitToWGS84(mapKit)
        expect(
            NavigationGeometryV1.distance(from: wgs84, to: roundTrip) < 0.5,
            "Watch and iPhone share sub-metre China coordinate normalization"
        )

        var cooldown = WatchRerouteCooldownV1()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        expect(cooldown.canAttempt(at: start), "first reroute is allowed")
        expect(
            !cooldown.canAttempt(at: start.addingTimeInterval(14.9)),
            "reroute cooldown rejects an early retry"
        )
        expect(
            cooldown.canAttempt(at: start.addingTimeInterval(15)),
            "reroute cooldown allows the exact boundary"
        )

        let request = WatchRouteRequestIdentityV1(
            navigationGeneration: 3,
            policyGeneration: 5,
            requestGeneration: 7,
            locationGeneration: 11
        )
        expect(
            request.isCurrent(
                navigationGeneration: 3,
                policyGeneration: 5,
                requestGeneration: 7,
                locationGeneration: 11,
                policy: .onlineAllowed
            ),
            "an exact online request generation is current"
        )
        expect(
            !request.isCurrent(
                navigationGeneration: 3,
                policyGeneration: 6,
                requestGeneration: 7,
                locationGeneration: 11,
                policy: .offlineOnly
            ),
            "a policy toggle invalidates a pending result"
        )
        expect(
            !request.isCurrent(
                navigationGeneration: 3,
                policyGeneration: 5,
                requestGeneration: 7,
                locationGeneration: 12,
                policy: .onlineAllowed
            ),
            "material motion invalidates a stale-origin result"
        )
    }

    private static func testWatchDirectBLEContract() throws {
        let credential = try WatchControllerCredentialV1(
            deviceID: "00112233445566778899aabbccddeeff",
            controllerID: Data([
                0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
                0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f,
            ]),
            key: Data([
                0xa0, 0x0f, 0xa1, 0x0e, 0xa2, 0x0d, 0xa3, 0x0c,
                0xa4, 0x0b, 0xa5, 0x0a, 0xa6, 0x09, 0xa7, 0x08,
                0xb8, 0x07, 0xc9, 0x06, 0xca, 0x05, 0xda, 0x04,
                0xea, 0x03, 0xfa, 0x02, 0xba, 0x01, 0xca, 0x00,
            ])
        )
        let clientNonce = Data([
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        ])
        let authentication = try WatchScopedAuthenticationV1(
            credential: credential,
            clientNonce: clientNonce
        )
        expect(
            authentication.hello ==
                "WATCH|102132435465768798a9bacbdcedfe0f|" +
                "000102030405060708090a0b0c0d0e0f",
            "Watch auth hello binds the full controller identity"
        )
        let serverNonce = "f0e0d0c0b0a090807060504030201000"
        let response =
            "WS2|102132435465768798a9bacbdcedfe0f|" +
            "000102030405060708090a0b0c0d0e0f|\(serverNonce)|" +
            "63d07c850925a02e71812b8c4d8f53a91027e25f8c8bd8e0c7a0dbe54961dc51"
        let challenge = try authentication.acceptServer(response)
        expect(
            challenge.proofCommand.hasSuffix(
                "be0cc00ab9922e4ecae2f4c4a06042a9a1048259b612fbc48d57b632998fcda9"
            ),
            "Watch auth proof matches the firmware transcript vector"
        )
        let session = try authentication.finish(
            "WOK2|000102030405060708090a0b0c0d0e0f|\(serverNonce)",
            challenge: challenge
        )
        let claim = try session.frame(
            payload: Data("LEASE_CLAIM".utf8),
            channel: .auth
        )
        expect(
            claim.count == Data("LEASE_CLAIM".utf8).count +
                WatchDirectBLEProtocolV1.protectedFrameOverhead &&
                claim.prefix(2) == Data([0x53, 0x32]),
            "Watch protected writes use S2 framing"
        )
        expectThrows(
            WatchScopedAuthenticationErrorV1.invalidServerProof,
            "tampered Watch server proofs are rejected"
        ) {
            _ = try authentication.acceptServer(
                response.dropLast() + "0"
            )
        }

        var cap2 = Data("CAP2".utf8)
        cap2.append(1)
        let flags = WatchDirectBLEProtocolV1.scopedControllerFeature |
            WatchDirectBLEProtocolV1.workoutTelemetryFeature
        cap2.append(UInt8(flags & 0xFF))
        cap2.append(UInt8((flags >> 8) & 0xFF))
        cap2.append(UInt8((flags >> 16) & 0xFF))
        cap2.append(UInt8((flags >> 24) & 0xFF))
        let capabilities = WatchDeviceCapabilitiesV1.decode(cap2)
        expect(
            capabilities?.supportsScopedController == true &&
                capabilities?.supportsWorkoutTelemetry == true,
            "Watch requires the direct-controller and workout capabilities"
        )
        var malformed = cap2
        malformed.append(contentsOf: [1, 4, 0, 0, 0])
        expect(
            WatchDeviceCapabilitiesV1.decode(malformed) == nil,
            "malformed capability TLVs are rejected"
        )

        var queue = WatchBLEOutboundQueueV1(capacity: 3)
        expect(queue.enqueue(.init(
            target: .route,
            payload: Data([1]),
            priority: 2,
            coalescingKey: "route"
        )), "route is queued")
        expect(queue.enqueue(.init(
            target: .gps,
            payload: Data([2]),
            priority: 1,
            coalescingKey: "gps"
        )), "GPS is queued")
        expect(queue.enqueue(.init(
            target: .gps,
            payload: Data([3]),
            priority: 1,
            coalescingKey: "gps"
        )), "new GPS coalesces")
        expect(queue.enqueue(.init(
            target: .navigation,
            payload: Data([4]),
            priority: 3
        )), "ordered maneuver is queued")
        expect(
            queue.dequeue()?.payload == Data([3]) &&
                queue.dequeue()?.payload == Data([1]) &&
                queue.dequeue()?.payload == Data([4]),
            "priority order is stable and only replaceable writes coalesce"
        )

        let location = sample(latitude: 1, longitude: 2, altitude: 3)
        expect(
            WatchRidePacketEncoderV1.gps(
                location,
                snapshot: nil
            ).count == 30,
            "Watch GPS payload matches the firmware binary schema"
        )
    }

    private static func testWatchControllerContract() throws {
        let deviceID = "00112233445566778899aabbccddeeff"
        let controllerID = Data([
            0x10, 0x21, 0x32, 0x43, 0x54, 0x65, 0x76, 0x87,
            0x98, 0xa9, 0xba, 0xcb, 0xdc, 0xed, 0xfe, 0x0f,
        ])
        let key = Data([
            0xa0, 0x0f, 0xa1, 0x0e, 0xa2, 0x0d, 0xa3, 0x0c,
            0xa4, 0x0b, 0xa5, 0x0a, 0xa6, 0x09, 0xa7, 0x08,
            0xb8, 0x07, 0xc9, 0x06, 0xca, 0x05, 0xda, 0x04,
            0xea, 0x03, 0xfa, 0x02, 0xba, 0x01, 0xca, 0x00,
        ])
        let challenge = Data([
            0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99, 0x88,
            0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00,
        ])
        let credential = try WatchControllerCredentialV1(
            deviceID: deviceID,
            controllerID: controllerID,
            key: key,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try expect(
            try WatchControllerCryptographyV1.enrollmentProof(
                credential: credential,
                challenge: challenge
            ).watchControllerHex ==
                "009f075c488a188a2874ccd7e924f437ed158a2fc42762f8060da789e9d1dd59",
            "Watch enrollment HMAC matches the firmware vector"
        )
        let request = WatchControllerRequestV1(
            requestID: UUID(
                uuidString: "11111111-2222-3333-4444-555555555555"
            )!,
            operation: .proveEnrollment,
            deviceID: deviceID,
            controllerID: controllerID,
            credential: credential,
            challenge: challenge
        )
        try expect(
            try WatchControllerRequestV1.decode(request.encoded()) == request,
            "Watch controller request round-trips"
        )
        let response = WatchControllerResponseV1(
            requestID: request.requestID,
            accepted: true,
            proof: try WatchControllerCryptographyV1.enrollmentProof(
                credential: credential,
                challenge: challenge
            )
        )
        try expect(
            try WatchControllerResponseV1.decode(response.encoded()) ==
                response,
            "Watch controller response round-trips"
        )
        expectThrows(
            WatchControllerContractError.invalidControllerID,
            "all-zero controller IDs are rejected"
        ) {
            _ = try WatchControllerCredentialV1(
                deviceID: deviceID,
                controllerID: Data(repeating: 0, count: 16),
                key: key
            )
        }
        expectThrows(
            WatchControllerContractError.invalidCredentialKey,
            "all-zero controller keys are rejected"
        ) {
            _ = try WatchControllerCredentialV1(
                deviceID: deviceID,
                controllerID: controllerID,
                key: Data(repeating: 0, count: 32)
            )
        }
    }

    private static func testArchiveIntegrityAndRetention() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let route = fixtureRoute(provider: RouteProviderPolicyV1.importedGPX)
        let archive = try NavigationRouteArchiveV1.create(
            route: route,
            createdAt: createdAt,
            deleteAfter: createdAt.addingTimeInterval(3_600),
            purpose: .offlineNavigation
        )
        let firstEncoding = try archive.encoded(
            purpose: .offlineNavigation,
            now: createdAt
        )
        let secondEncoding = try archive.encoded(
            purpose: .offlineNavigation,
            now: createdAt
        )
        expect(firstEncoding == secondEncoding, "archive encoding is deterministic")
        expect(archive.contentHash.count == 64, "archive uses a SHA-256 hex digest")
        let decoded = try NavigationRouteArchiveV1.decode(
            firstEncoding,
            purpose: .offlineNavigation,
            now: createdAt
        )
        expect(decoded == archive, "archive round-trips exactly")

        let submillisecondArchive = try NavigationRouteArchiveV1.create(
            route: route,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.123_456),
            purpose: .offlineNavigation
        )
        let submillisecondData = try submillisecondArchive.encoded(
            purpose: .offlineNavigation,
            now: submillisecondArchive.createdAt
        )
        try expect(
            try NavigationRouteArchiveV1.decode(
                submillisecondData,
                purpose: .offlineNavigation,
                now: submillisecondArchive.createdAt
            ) == submillisecondArchive,
            "archive creation normalizes dates for exact round trips"
        )

        let corrupted = NavigationRouteArchiveV1(
            schemaVersion: archive.schemaVersion,
            route: archive.route,
            createdAt: archive.createdAt,
            deleteAfter: archive.deleteAfter,
            contentHash: String(repeating: "0", count: 64)
        )
        expectThrows(
            NavigationRouteArchiveError.hashMismatch,
            "corrupted archive hash is rejected"
        ) {
            try corrupted.validate(purpose: .offlineNavigation, now: createdAt)
        }
        expectThrows(
            NavigationRouteArchiveError.expired,
            "expired routes are rejected"
        ) {
            try archive.validate(
                purpose: .offlineNavigation,
                now: createdAt.addingTimeInterval(3_600)
            )
        }
        let wrongSchema = NavigationRouteArchiveV1(
            schemaVersion: 99,
            route: archive.route,
            createdAt: archive.createdAt,
            deleteAfter: archive.deleteAfter,
            contentHash: archive.contentHash
        )
        expectThrows(
            NavigationRouteArchiveError.invalidSchemaVersion(99),
            "unknown archive schemas are rejected before use"
        ) {
            try wrongSchema.validate(
                purpose: .offlineNavigation,
                now: createdAt
            )
        }
        expectThrows(
            NavigationRouteArchiveError.invalidDeletionDate,
            "non-forward retention dates are rejected"
        ) {
            _ = try NavigationRouteArchiveV1.create(
                route: route,
                createdAt: createdAt,
                deleteAfter: createdAt,
                purpose: .offlineNavigation
            )
        }
        expectThrows(
            NavigationRouteArchiveError.invalidEncoding,
            "malformed archive bytes are rejected"
        ) {
            _ = try NavigationRouteArchiveV1.decode(
                Data("not-json".utf8),
                purpose: .offlineNavigation,
                now: createdAt
            )
        }

        let mapKitRoute = fixtureRoute(provider: RouteProviderPolicyV1.mapKit)
        expectThrows(
            NavigationRouteArchiveError.durableStorageNotAllowed(
                providerID: RouteProviderPolicyV1.mapKit.providerID
            ),
            "MapKit durable export is fail-closed"
        ) {
            _ = try NavigationRouteArchiveV1.create(
                route: mapKitRoute,
                createdAt: createdAt,
                purpose: .durableStorage
            )
        }
        _ = try NavigationRouteArchiveV1.create(
            route: mapKitRoute,
            createdAt: createdAt,
            purpose: .activeUse
        )
        let forgedMapKitPolicy = RouteProviderMetadataV1(
            providerID: RouteProviderPolicyV1.mapKit.providerID,
            attribution: RouteProviderPolicyV1.mapKit.attribution,
            storageScope: .durable
        )
        expectThrows(
            NavigationRouteValidationError.invalidProvider,
            "known providers cannot self-upgrade their retention policy"
        ) {
            try fixtureRoute(provider: forgedMapKitPolicy).validate()
        }
        let unknownDurablePolicy = RouteProviderMetadataV1(
            providerID: "unreviewed.provider",
            attribution: "Unreviewed",
            storageScope: .durable
        )
        expectThrows(
            NavigationRouteArchiveError.durableStorageNotAllowed(
                providerID: unknownDurablePolicy.providerID
            ),
            "unreviewed providers are denied durable storage"
        ) {
            _ = try NavigationRouteArchiveV1.create(
                route: fixtureRoute(provider: unknownDurablePolicy),
                createdAt: createdAt,
                purpose: .offlineNavigation
            )
        }

        let tinyLimits = NavigationRouteLimitsV1(
            maximumPoints: 100,
            maximumSteps: 10,
            maximumEncodedBytes: 32
        )
        expectThrows(
            NavigationRouteArchiveError.encodedSizeExceeded,
            "encoded-size limit is enforced before persistence"
        ) {
            _ = try archive.encoded(
                purpose: .offlineNavigation,
                now: createdAt,
                limits: tinyLimits
            )
        }
    }

    private static func testRouteValidationBoundaries() throws {
        let valid = fixtureRoute(provider: RouteProviderPolicyV1.importedGPX)
        try valid.validate()
        expectThrows(
            NavigationRouteValidationError.tooManyPoints,
            "point-count limits are enforced"
        ) {
            try valid.validate(limits: NavigationRouteLimitsV1(
                maximumPoints: 2,
                maximumSteps: 10,
                maximumEncodedBytes: 4 * 1_024 * 1_024
            ))
        }
        expectThrows(
            NavigationRouteValidationError.tooManySteps,
            "step-count limits are enforced"
        ) {
            try valid.validate(limits: NavigationRouteLimitsV1(
                maximumPoints: 10,
                maximumSteps: 1,
                maximumEncodedBytes: 4 * 1_024 * 1_024
            ))
        }
        let invalidLocale = copyRoute(valid, localeIdentifier: " ")
        expectThrows(
            NavigationRouteValidationError.invalidLocale,
            "blank locales are rejected"
        ) {
            try invalidLocale.validate()
        }

        let duplicateStep = NavigationRouteV1(
            id: valid.id,
            revision: valid.revision,
            provider: valid.provider,
            localeIdentifier: valid.localeIdentifier,
            transportType: valid.transportType,
            source: valid.source,
            destination: valid.destination,
            bounds: valid.bounds,
            distanceMeters: valid.distanceMeters,
            expectedTravelTimeSeconds: valid.expectedTravelTimeSeconds,
            name: valid.name,
            points: valid.points,
            steps: [valid.steps[0], valid.steps[0]],
            normalizationVersion: valid.normalizationVersion
        )
        expectThrows(
            NavigationRouteValidationError.duplicateStepID(valid.steps[0].id),
            "duplicate step IDs are rejected"
        ) {
            try duplicateStep.validate()
        }

        let invalidPoint = RouteCoordinateV1(latitude: .nan, longitude: 0)
        let invalidGeometry = NavigationRouteV1(
            id: valid.id,
            revision: valid.revision,
            provider: valid.provider,
            localeIdentifier: valid.localeIdentifier,
            transportType: valid.transportType,
            source: valid.source,
            destination: valid.destination,
            bounds: valid.bounds,
            distanceMeters: valid.distanceMeters,
            expectedTravelTimeSeconds: valid.expectedTravelTimeSeconds,
            name: valid.name,
            points: [valid.points[0], invalidPoint],
            steps: valid.steps,
            normalizationVersion: valid.normalizationVersion
        )
        expectThrows(
            NavigationRouteValidationError.invalidCoordinate(index: 1),
            "non-finite coordinates are rejected"
        ) {
            try invalidGeometry.validate()
        }

        let mismatchedEndpoint = NavigationRouteV1(
            id: valid.id,
            revision: valid.revision,
            provider: valid.provider,
            localeIdentifier: valid.localeIdentifier,
            transportType: valid.transportType,
            source: RouteEndpointV1(
                coordinate: valid.points[1],
                label: valid.source.label
            ),
            destination: valid.destination,
            bounds: valid.bounds,
            distanceMeters: valid.distanceMeters,
            expectedTravelTimeSeconds: valid.expectedTravelTimeSeconds,
            name: valid.name,
            points: valid.points,
            steps: valid.steps,
            normalizationVersion: valid.normalizationVersion
        )
        expectThrows(
            NavigationRouteValidationError.endpointGeometryMismatch,
            "route endpoints must be pinned to archive geometry"
        ) {
            try mismatchedEndpoint.validate()
        }

        let sparsePoints = [
            RouteCoordinateV1(latitude: 0, longitude: 0),
            RouteCoordinateV1(latitude: 0, longitude: 0.1)
        ]
        let sparseRoute = NavigationRouteV1(
            id: valid.id,
            revision: valid.revision,
            provider: valid.provider,
            localeIdentifier: valid.localeIdentifier,
            transportType: valid.transportType,
            source: RouteEndpointV1(coordinate: sparsePoints[0], label: "Start"),
            destination: RouteEndpointV1(coordinate: sparsePoints[1], label: "Finish"),
            bounds: RouteBoundsV1.enclosing(sparsePoints)!,
            distanceMeters: 11_120,
            expectedTravelTimeSeconds: nil,
            name: nil,
            points: sparsePoints,
            steps: [
                NavigationRouteStepV1(
                    id: 1,
                    geometryStartIndex: 0,
                    geometryEndIndex: 1,
                    instruction: "Continue",
                    maneuver: .straight,
                    distanceMeters: 11_120
                )
            ],
            normalizationVersion: 1
        )
        expectThrows(
            NavigationRouteValidationError.unencodableGeometrySegment(index: 0),
            "geometry that would corrupt the device delta stream is rejected"
        ) {
            try sparseRoute.validate()
        }

        let discontinuous = copyRoute(
            valid,
            steps: [
                NavigationRouteStepV1(
                    id: 1,
                    geometryStartIndex: 0,
                    geometryEndIndex: 0,
                    instruction: "Continue",
                    maneuver: .straight,
                    distanceMeters: 0
                ),
                NavigationRouteStepV1(
                    id: 2,
                    geometryStartIndex: 1,
                    geometryEndIndex: 2,
                    instruction: "Arrive",
                    maneuver: .arrive,
                    distanceMeters: valid.distanceMeters
                )
            ]
        )
        expectThrows(
            NavigationRouteValidationError.discontinuousStepRange(index: 1),
            "step geometry must cover the route without gaps"
        ) {
            try discontinuous.validate()
        }
    }

    private static func testRuntimeProgressDeviationAndReplacement() throws {
        let route = fixtureRoute(provider: RouteProviderPolicyV1.importedGPX)
        var runtime = NavigationRuntimeV1()
        let distant = sample(latitude: 0.004, longitude: 0)
        let assessment = try runtime.start(
            route: route,
            contentHash: "fixture",
            mode: .offline,
            initialLocation: distant
        )
        expect(assessment.requiresConfirmation, "distant starts require confirmation")

        runtime.stop()
        _ = try runtime.start(
            route: route,
            contentHash: "fixture",
            mode: .offline,
            initialLocation: sample(latitude: 0, longitude: 0)
        )
        let first = try runtime.process(sample(latitude: 0, longitude: 0.0004))
        _ = try runtime.process(sample(latitude: 0, longitude: 0.0010))
        let second = try runtime.process(sample(latitude: 0, longitude: 0.0014))
        expect(
            second.routeRemainingDistanceMeters < first.routeRemainingDistanceMeters,
            "route progress is monotonic"
        )
        expect(second.currentStepIndex == 1, "runtime advances to the next geometry-indexed step")
        expect(second.routeWindow.count <= 124, "device route window stays within 30 points")

        let offRoute = sample(
            latitude: 0.001,
            longitude: 0.0014,
            timestamp: 1_700_000_001
        )
        try expect(try runtime.process(offRoute).offRouteDistanceMeters == nil,
                   "first deviation sample does not declare off-route")
        try expect(try runtime.process(offRoute).offRouteDistanceMeters == nil,
                   "a duplicate GPS fix is idempotent")
        try expect(
            try runtime.process(
                sample(
                    latitude: 0.001,
                    longitude: 0.0014,
                    timestamp: 1_700_000_002
                )
            ).offRouteDistanceMeters == nil,
            "second distinct deviation sample does not declare off-route"
        )
        try expect(try runtime.process(sample(
            latitude: 0.001,
            longitude: 0.0014,
            timestamp: 1_700_000_003
        )).offRouteDistanceMeters != nil,
                   "third eligible deviation sample declares off-route")
        try expect(
            try runtime.process(sample(latitude: 0, longitude: 0.0015))
                .offRouteDistanceMeters == nil,
            "returning to the route clears deviation state"
        )

        let generationBeforeReplacement = runtime.generation
        let replacement = fixtureRoute(
            provider: RouteProviderPolicyV1.importedGPX,
            routeID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
        let routeBeforeFailedReplacement = runtime.route
        let snapshotBeforeFailedReplacement = runtime.snapshot
        let generationBeforeFailedReplacement = runtime.generation
        expectThrows(
            NavigationRuntimeError.invalidLocation,
            "failed replacement is non-destructive"
        ) {
            _ = try runtime.replaceRoute(
                replacement,
                contentHash: "replacement",
                mode: .online,
                currentLocation: sample(latitude: .nan, longitude: 0)
            )
        }
        expect(runtime.route == routeBeforeFailedReplacement,
               "failed replacement preserves the active route")
        expect(runtime.snapshot == snapshotBeforeFailedReplacement,
               "failed replacement preserves the active snapshot")
        expect(runtime.generation == generationBeforeFailedReplacement,
               "failed replacement preserves navigation generation")

        let replacementSnapshot = try runtime.replaceRoute(
            replacement,
            contentHash: "replacement",
            mode: .online,
            currentLocation: sample(latitude: 0, longitude: 0.0015)
        )
        expect(runtime.generation != generationBeforeReplacement,
               "route replacement advances navigation generation")
        expect(replacementSnapshot.routeID == replacement.id,
               "replacement snapshot identifies the new route")

        var recoveredRuntime = NavigationRuntimeV1()
        _ = try recoveredRuntime.start(
            route: route,
            mode: .offline,
            initialStepStrategy: .checkpoint(stepIndex: 1),
            initialLocation: sample(latitude: 0, longitude: 0.0001)
        )
        expect(
            recoveredRuntime.snapshot?.currentStepIndex == 1,
            "a recovery checkpoint never regresses to an earlier loop segment"
        )
        expectThrows(
            NavigationRuntimeError.invalidCheckpoint,
            "out-of-range recovery checkpoints are rejected atomically"
        ) {
            _ = try recoveredRuntime.start(
                route: route,
                mode: .offline,
                initialStepStrategy: .checkpoint(stepIndex: 99),
                initialLocation: sample(latitude: 0, longitude: 0)
            )
        }

        var failedStart = NavigationRuntimeV1()
        expectThrows(
            NavigationRuntimeError.invalidLocation,
            "failed start is atomic"
        ) {
            _ = try failedStart.start(
                route: route,
                mode: .offline,
                initialLocation: sample(
                    latitude: 0,
                    longitude: 0,
                    altitude: .nan
                )
            )
        }
        expect(failedStart.route == nil && failedStart.generation == 0,
               "failed start leaves a stopped runtime")
    }

    private static func testRouteFileStoreAndSyncContract() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-bike-route-store-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NavigationRouteFileStoreV1(rootDirectory: root)
        let route = fixtureRoute(provider: RouteProviderPolicyV1.importedGPX)
        let archive = try NavigationRouteArchiveV1.create(
            route: route,
            createdAt: now,
            deleteAfter: now.addingTimeInterval(3_600),
            purpose: .offlineNavigation
        )
        let data = try archive.encoded(
            purpose: .offlineNavigation,
            now: now
        )
        let identity = WatchRouteIdentityV1(archive: archive)
        let message = WatchRouteSyncMessageV1(
            operation: .install,
            identity: identity,
            encodedByteCount: data.count,
            deleteAfter: archive.deleteAfter
        )
        expect(
            WatchRouteSyncMessageV1(propertyList: message.propertyList) == message,
            "route transfer metadata round-trips through property-list values"
        )
        var malformed = message.propertyList
        malformed["bicino.route.hash"] = identity.contentHash.uppercased()
        expect(
            WatchRouteSyncMessageV1(propertyList: malformed) == nil,
            "non-canonical route hashes are rejected"
        )
        let missingByteCount = WatchRouteSyncMessageV1(
            operation: .install,
            identity: identity
        )
        expect(
            WatchRouteSyncMessageV1(
                propertyList: missingByteCount.propertyList
            ) == nil,
            "install metadata requires the exact encoded byte count"
        )
        let invalidReady = WatchRouteSyncMessageV1(
            operation: .acknowledge,
            identity: identity,
            status: .ready,
            errorCode: "unexpected"
        )
        expect(
            WatchRouteSyncMessageV1(propertyList: invalidReady.propertyList) == nil,
            "successful acknowledgements cannot carry failure codes"
        )

        let installed = try store.install(data, now: now)
        expect(installed.archive == archive, "validated route archive installs")
        let repeatedInstall = try store.install(data, now: now)
        expect(repeatedInstall.fileURL == installed.fileURL,
               "idempotent install keeps the same file URL")
        expect(repeatedInstall.archive.contentHash == installed.archive.contentHash,
               "idempotent install keeps the same content hash")
        let loadedRecord = try store.record(matching: identity, now: now)
        expect(
            loadedRecord.fileURL == installed.fileURL &&
                loadedRecord.archive.contentHash == installed.archive.contentHash,
            "installed routes are addressable by complete identity"
        )

        let revisionTwoRoute = copyRoute(route, revision: 2)
        let revisionTwo = try NavigationRouteArchiveV1.create(
            route: revisionTwoRoute,
            createdAt: now.addingTimeInterval(1),
            deleteAfter: now.addingTimeInterval(3_600),
            purpose: .offlineNavigation
        )
        let revisionTwoData = try revisionTwo.encoded(
            purpose: .offlineNavigation,
            now: now.addingTimeInterval(1)
        )
        _ = try store.install(revisionTwoData, now: now.addingTimeInterval(1))
        expectThrows(
            NavigationRouteFileStoreError.staleRevision,
            "delayed old route transfers cannot replace a newer revision"
        ) {
            _ = try store.install(data, now: now.addingTimeInterval(2))
        }

        let conflictRoute = copyRoute(
            revisionTwoRoute,
            localeIdentifier: "en_GB"
        )
        let conflict = try NavigationRouteArchiveV1.create(
            route: conflictRoute,
            createdAt: now.addingTimeInterval(2),
            deleteAfter: now.addingTimeInterval(3_600),
            purpose: .offlineNavigation
        )
        let conflictData = try conflict.encoded(
            purpose: .offlineNavigation,
            now: now.addingTimeInterval(2)
        )
        expectThrows(
            NavigationRouteFileStoreError.revisionConflict,
            "one revision cannot identify two route contents"
        ) {
            _ = try store.install(conflictData, now: now.addingTimeInterval(2))
        }

        let revisionTwoIdentity = WatchRouteIdentityV1(archive: revisionTwo)
        try store.delete(matching: revisionTwoIdentity, now: now.addingTimeInterval(2))
        expect(store.records(now: now.addingTimeInterval(2)).isEmpty,
               "exact route deletion removes the installed archive")

        let expiring = try NavigationRouteArchiveV1.create(
            route: copyRoute(route, revision: 3),
            createdAt: now,
            deleteAfter: now.addingTimeInterval(10),
            purpose: .offlineNavigation
        )
        _ = try store.install(
            try expiring.encoded(purpose: .offlineNavigation, now: now),
            now: now
        )
        expect(store.pruneInvalidAndExpired(now: now.addingTimeInterval(10)) == 1,
               "expired route files are removed from durable storage")

        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let corruptURL = root.appendingPathComponent("corrupt.routev1")
        try Data("not an archive".utf8).write(to: corruptURL)
        expect(store.pruneInvalidAndExpired(now: now) == 1,
               "corrupt route files are removed from the selectable library")
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Quarantine", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        expect(quarantined.count == 1,
               "corrupt route diagnostics are quarantined with a strict bound")

        for index in 0..<5 {
            try Data("bad \(index)".utf8).write(
                to: root.appendingPathComponent("corrupt-\(index).routev1")
            )
        }
        _ = store.pruneInvalidAndExpired(now: now)
        let boundedQuarantine = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Quarantine", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        expect(boundedQuarantine.count == 3,
               "quarantined diagnostics retain at most three files")

        let capacityRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "open-bike-route-capacity-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: capacityRoot) }
        let boundedStore = NavigationRouteFileStoreV1(
            rootDirectory: capacityRoot,
            limits: NavigationRouteFileStoreLimitsV1(
                maximumArchiveCount: 1,
                maximumTotalEncodedBytes: 4 * 1_024 * 1_024
            )
        )
        _ = try boundedStore.install(data, now: now)
        let secondRoute = fixtureRoute(
            provider: RouteProviderPolicyV1.importedGPX,
            routeID: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        )
        let secondArchive = try NavigationRouteArchiveV1.create(
            route: secondRoute,
            createdAt: now,
            purpose: .offlineNavigation
        )
        expectThrows(
            NavigationRouteFileStoreError.capacityExceeded,
            "store-specific archive counts are enforced before writing"
        ) {
            _ = try boundedStore.install(
                try secondArchive.encoded(
                    purpose: .offlineNavigation,
                    now: now
                ),
                now: now
            )
        }
    }

    private static func fixtureRoute(
        provider: RouteProviderMetadataV1,
        routeID: UUID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    ) -> NavigationRouteV1 {
        let points = [
            RouteCoordinateV1(latitude: 0, longitude: 0),
            RouteCoordinateV1(latitude: 0, longitude: 0.001),
            RouteCoordinateV1(latitude: 0, longitude: 0.002)
        ]
        return NavigationRouteV1(
            id: routeID,
            revision: 1,
            provider: provider,
            localeIdentifier: "en_US",
            transportType: .cycling,
            source: RouteEndpointV1(coordinate: points[0], label: "Start"),
            destination: RouteEndpointV1(coordinate: points[2], label: "Finish"),
            bounds: RouteBoundsV1.enclosing(points)!,
            distanceMeters: 222.4,
            expectedTravelTimeSeconds: 120,
            name: "Fixture route",
            points: points,
            steps: [
                NavigationRouteStepV1(
                    id: 1,
                    geometryStartIndex: 0,
                    geometryEndIndex: 1,
                    instruction: "Turn right",
                    maneuver: .right,
                    distanceMeters: 111.2
                ),
                NavigationRouteStepV1(
                    id: 2,
                    geometryStartIndex: 1,
                    geometryEndIndex: 2,
                    instruction: "Arrive at destination",
                    maneuver: .arrive,
                    distanceMeters: 111.2
                )
            ],
            normalizationVersion: 1
        )
    }

    private static func copyRoute(
        _ route: NavigationRouteV1,
        revision: UInt32? = nil,
        localeIdentifier: String? = nil,
        steps: [NavigationRouteStepV1]? = nil
    ) -> NavigationRouteV1 {
        NavigationRouteV1(
            id: route.id,
            revision: revision ?? route.revision,
            provider: route.provider,
            localeIdentifier: localeIdentifier ?? route.localeIdentifier,
            transportType: route.transportType,
            source: route.source,
            destination: route.destination,
            bounds: route.bounds,
            distanceMeters: route.distanceMeters,
            expectedTravelTimeSeconds: route.expectedTravelTimeSeconds,
            name: route.name,
            points: route.points,
            steps: steps ?? route.steps,
            normalizationVersion: route.normalizationVersion
        )
    }

    private static func sample(
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double = 5,
        altitude: Double = 0,
        timestamp: TimeInterval = 1_700_000_000
    ) -> NavigationLocationSampleV1 {
        NavigationLocationSampleV1(
            coordinate: RouteCoordinateV1(latitude: latitude, longitude: longitude),
            horizontalAccuracyMeters: horizontalAccuracy,
            courseDegrees: 0,
            speedMetersPerSecond: 5,
            altitudeMeters: altitude,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) rethrows {
        guard try condition() else {
            fatalError("FAILED: \(message)")
        }
    }

    private static func expectThrows<E: Error & Equatable>(
        _ expected: E,
        _ message: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            fatalError("FAILED: \(message) (no error)")
        } catch let error as E {
            expect(error == expected, "\(message) (got \(error))")
        } catch {
            fatalError("FAILED: \(message) (unexpected \(error))")
        }
    }
}
