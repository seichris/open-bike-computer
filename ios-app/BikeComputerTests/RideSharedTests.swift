import Foundation

@main
enum RideSharedTests {
    static func main() throws {
        try testArchiveIntegrityAndRetention()
        try testRouteValidationBoundaries()
        try testRuntimeProgressDeviationAndReplacement()
        try testRouteFileStoreAndSyncContract()
        try testWatchControllerContract()
        try testRideBLETransportStateMachine()
        try testRideBLEATTWatchdogPolicy()
        try testWatchDirectBLEContract()
        testMotionDispatchAge()
        try testFavoriteSyncPolicyAndCoordinateNormalization()
        try testGPXImport()
        try testStravaAthleteRoutePages()
        try testStravaRouteContractAndReloadBookmarks()
        print("RideSharedTests passed")
    }

    private static func testMotionDispatchAge() {
        var frame = Data(repeating: 0, count: 16)
        frame[0] = 4
        frame[12] = 100
        let dispatch = RideBLEMotionDispatch(frame: frame, enqueuedUptime: 10)
        let delayed = dispatch.payload(at: 12)!
        expect(Int(delayed[12]) + (Int(delayed[13]) << 8) == 2100,
               "queued age includes monotonic writer delay")
        expect(dispatch.payload(at: 13) == nil, "expired motion is dropped before ATT")
        expect(dispatch.payload(at: 9) == nil, "invalid monotonic clock fails closed")
        let write = WatchBLEOutboundWriteV1(target: .workout,
                                           payload: frame, motionDispatch: dispatch)
        expect(write.motionDispatch?.payload(at: 13) == nil,
               "Watch queue retains original admission time through backpressure")
    }

    private static func testRideBLETransportStateMachine() throws {
        for role in [
            RideBLEControllerRoleV1.ownerPhone,
            .scopedWatch,
        ] {
            var transport = RideBLETransportStateMachineV1(role: role)
            expect(
                transport.reduce(.beginConnection) == .applied &&
                    transport.generation == 1 &&
                    transport.phase == .connecting,
                "\(role.rawValue) begins one generation-scoped connection"
            )
            expect(
                transport.reduce(.linkConnected(generation: 0)) ==
                    .ignoredStaleGeneration &&
                    transport.phase == .connecting,
                "\(role.rawValue) ignores a late callback from an old connection"
            )
            expect(
                transport.reduce(.linkConnected(generation: 1)) == .applied &&
                    transport.reduce(.authenticated(generation: 1)) == .applied,
                "\(role.rawValue) advances through link and authentication"
            )
            expect(
                transport.reduce(.capabilitiesAccepted(
                    generation: 1,
                    schemaVersion: 20
                )) == .rejectedInvalidTransition,
                "\(role.rawValue) cannot report Ready before its firmware lease"
            )
            expect(
                transport.reduce(.leaseAccepted(
                    generation: 1,
                    leaseGeneration: 7
                )) == .applied &&
                    transport.reduce(.capabilitiesAccepted(
                        generation: 1,
                        schemaVersion: 20
                    )) == .becameReady &&
                    transport.isReady,
                "\(role.rawValue) becomes Ready only after auth, lease, and capabilities"
            )
            let commandID = UUID()
            expect(
                transport.reduce(.writerChanged(
                    generation: 1,
                    state: .waitingForApplicationAcknowledgement(
                        commandID: commandID
                    )
                )) == .applied && transport.isReady,
                "\(role.rawValue) remains authenticated while one critical ACK is pending"
            )
            expect(
                transport.reduce(.failed(
                    generation: 1,
                    reason: .applicationTimeout
                )) == .leftReady &&
                    !transport.isReady &&
                    transport.lastFailure == .applicationTimeout,
                "\(role.rawValue) cannot stay Ready after writer recovery begins"
            )
            expect(
                transport.reduce(.disconnected(generation: 1)) == .applied &&
                    transport.generation == 2 &&
                    transport.phase == .idle &&
                    transport.leaseGeneration == nil,
                "\(role.rawValue) discards connection-scoped authority on disconnect"
            )
        }

        var stopping = RideBLETransportStateMachineV1(role: .scopedWatch)
        _ = stopping.reduce(.beginConnection)
        _ = stopping.reduce(.linkConnected(generation: 1))
        _ = stopping.reduce(.authenticated(generation: 1))
        _ = stopping.reduce(.leaseAccepted(
            generation: 1,
            leaseGeneration: 11
        ))
        _ = stopping.reduce(.capabilitiesAccepted(
            generation: 1,
            schemaVersion: 20
        ))
        expect(
            stopping.reduce(.stopRequested(generation: 1)) == .leftReady &&
                stopping.reduce(.leaseReleased(generation: 1)) == .applied &&
                stopping.leaseGeneration == nil,
            "a Watch stop cannot remain Ready while its lease is releasing"
        )
    }

    private static func testRideBLEATTWatchdogPolicy() throws {
        expect(
            RideBLEATTWatchdogPolicyV1.minimumTimeoutSeconds == 5 &&
                RideBLEATTWatchdogPolicyV1.maximumTimeoutSeconds == 15,
            "ATT watchdog production bounds remain explicit"
        )
        expect(
            RideBLEATTWatchdogPolicyV1.timeoutSeconds(
                for: .criticalApplication
            ) == 8 &&
                RideBLEATTWatchdogPolicyV1.timeoutSeconds(
                    for: .transferControl
                ) == 15,
            "critical state and transfer control use bounded class-aware waits"
        )
        expect(
            RideBLEATTWatchdogPolicyV1.recovery(for: .authentication) ==
                .restartAuthentication &&
                RideBLEATTWatchdogPolicyV1.recovery(
                    for: .replaceableSnapshot
                ) == .reconnectAndResynchronize,
            "timeouts never request a blind same-generation write retry"
        )
    }

    private static func testStravaAthleteRoutePages() throws {
        func route(_ id: Int, type: String = "ride") -> [String: Any] {
            [
                "routeId": String(id),
                "name": "Route \(id)",
                "distanceMeters": Double(id) * 1_000,
                "elevationGainMeters": Double(id) * 10,
                "type": type,
            ]
        }

        let shortData = try JSONSerialization.data(withJSONObject: [
            "page": 1,
            "nextPage": NSNull(),
            "routes": [route(101), route(102, type: "run")],
        ])
        let shortPage = try JSONDecoder().decode(
            StravaAthleteRoutePageV1.self,
            from: shortData
        )
        expect(
            shortPage.page == 1 &&
                shortPage.nextPage == nil &&
                shortPage.routes.map(\.type) == [.ride, .run] &&
                shortPage.routes[0].routeURL?.canonicalURL ==
                    "https://www.strava.com/routes/101" &&
                shortPage.routes[0].type.isImportable &&
                !shortPage.routes[1].type.isImportable,
            "a safe route page exposes canonical route identity and importability"
        )

        let fullData = try JSONSerialization.data(withJSONObject: [
            "page": 1,
            "nextPage": 2,
            "routes": (1...200).map { route($0) },
        ])
        let fullPage = try JSONDecoder().decode(
            StravaAthleteRoutePageV1.self,
            from: fullData
        )
        expect(
            fullPage.routes.count == 200 && fullPage.nextPage == 2,
            "a full Strava response explicitly advances pagination"
        )

        let duplicateData = try JSONSerialization.data(withJSONObject: [
            "page": 1,
            "nextPage": NSNull(),
            "routes": [route(101), route(101)],
        ])
        expectThrows(
            StravaRouteContractError.invalidResponseContract,
            "duplicate route identities fail closed"
        ) {
            _ = try JSONDecoder().decode(
                StravaAthleteRoutePageV1.self,
                from: duplicateData
            )
        }

        let inconsistentData = try JSONSerialization.data(withJSONObject: [
            "page": 1,
            "nextPage": 2,
            "routes": [route(101)],
        ])
        expectThrows(
            StravaRouteContractError.invalidResponseContract,
            "a partial response cannot advertise another page"
        ) {
            _ = try JSONDecoder().decode(
                StravaAthleteRoutePageV1.self,
                from: inconsistentData
            )
        }
    }

    private static func testStravaRouteContractAndReloadBookmarks() throws {
        let rawURL = " https://www.strava.com/routes/3009840108578231836\n"
        let routeURL = try StravaRouteURLV1(rawURL)
        expect(
            routeURL.externalRouteID == "3009840108578231836" &&
                routeURL.canonicalURL ==
                    "https://www.strava.com/routes/3009840108578231836",
            "a canonical Strava route URL is parsed without retaining raw input"
        )
        for accepted in [
            "https://strava.com/routes/3009840108578231836",
            "https://www.strava.com/routes/3009840108578231836/",
            "https://www.strava.com/routes/3009840108578231836?utm=test",
            "https://www.strava.com/routes/3009840108578231836#map"
        ] {
            try expect(
                try StravaRouteURLV1(accepted) == routeURL,
                "supported Strava URL variants canonicalize"
            )
        }
        for invalid in [
            "http://www.strava.com/routes/3009840108578231836",
            "https://www.strava.com/segments/3009840108578231836",
            "https://share.strava.com/routes/3009840108578231836",
            "https://www.strava.com:444/routes/3009840108578231836",
            "https://user@www.strava.com/routes/3009840108578231836",
            "https://www.strava.com/routes/3009840108578231836/extra",
            "https://www.strava.com/routes/9223372036854775808"
        ] {
            expectThrows(
                StravaRouteContractError.invalidURL,
                "non-canonical Strava URL \(invalid) fails closed"
            ) {
                _ = try StravaRouteURLV1(invalid)
            }
        }

        let oauthSessionID =
            "oauth_abcdefghijklmnopqrstuvwxyz0123456789"
        let callback = URL(
            string: "bikecomputer-dev://strava/oauth-complete?" +
                "result=connected&sessionId=\(oauthSessionID)"
        )!
        expect(
            StravaOAuthCallbackV1.parse(
                callback,
                expectedScheme: "bikecomputer-dev",
                expectedSessionID: oauthSessionID
            ) == StravaOAuthCallbackV1(
                result: .connected,
                sessionID: oauthSessionID
            ),
            "the exact OAuth callback route and session are accepted"
        )
        expect(
            StravaOAuthCallbackV1.matchesReturnLocation(
                callback,
                expectedScheme: "bikecomputer-dev"
            ),
            "the Strava callback location is claimed before query parsing"
        )
        expect(
            !StravaOAuthCallbackV1.matchesReturnLocation(
                URL(string: "bikecomputer-dev://offline-map/share?id=route")!,
                expectedScheme: "bikecomputer-dev"
            ) &&
                !StravaOAuthCallbackV1.matchesReturnLocation(
                    callback,
                    expectedScheme: "bikecomputer"
                ),
            "unrelated deep links and the other app channel are not consumed"
        )
        for confusedCallback in [
            "bikecomputer://strava/oauth-complete?result=connected&sessionId=\(oauthSessionID)",
            "bikecomputer-dev://strava.example/oauth-complete?result=connected&sessionId=\(oauthSessionID)",
            "bikecomputer-dev://strava/oauth-complete/extra?result=connected&sessionId=\(oauthSessionID)",
            "bikecomputer-dev://strava/oauth-complete?result=connected&sessionId=oauth_wrongwrongwrongwrongwrongwrong",
            "bikecomputer-dev://strava/oauth-complete?result=connected&result=denied&sessionId=\(oauthSessionID)",
            "bikecomputer-dev://strava/oauth-complete?result=connected&sessionId=\(oauthSessionID)&next=https://example.com"
        ] {
            expect(
                StravaOAuthCallbackV1.parse(
                    URL(string: confusedCallback)!,
                    expectedScheme: "bikecomputer-dev",
                    expectedSessionID: oauthSessionID
                ) == nil,
                "OAuth callback scheme, route, query, and session fail closed"
            )
        }

        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let deleteAfter = fetchedAt.addingTimeInterval(
            RouteProviderPolicyV1.stravaRouteMaximumRetentionSeconds
        )
        let receipt = try StravaRouteImportReceiptV1(
            routeURL: routeURL,
            fetchedAt: fetchedAt,
            deleteAfter: deleteAfter,
            validatedAt: fetchedAt
        )
        expectThrows(
            StravaRouteContractError.invalidCacheLifetime,
            "a backend response cannot extend or shorten the seven-day window"
        ) {
            _ = try StravaRouteImportReceiptV1(
                routeURL: routeURL,
                fetchedAt: fetchedAt,
                deleteAfter: deleteAfter.addingTimeInterval(1),
                validatedAt: fetchedAt
            )
        }
        let fetchedAtText = "2023-11-14T22:13:20Z"
        let deleteAfterText = "2023-11-21T22:13:20Z"
        let minimalGPX = Data("<gpx/>".utf8)
        let response = try StravaRouteImportResponseV1.validate(
            gpx: minimalGPX,
            requestedRouteURL: routeURL,
            contentType: "application/gpx+xml; charset=utf-8",
            cacheControl: "private, no-store",
            providerID: RouteProviderPolicyV1.strava.providerID,
            externalRouteID: routeURL.externalRouteID,
            fetchedAt: fetchedAtText,
            deleteAfter: deleteAfterText,
            now: fetchedAt
        )
        expect(
            response.gpx == minimalGPX && response.receipt == receipt,
            "the exact Strava GPX response contract produces a receipt"
        )
        expectThrows(
            StravaRouteContractError.emptyResponse,
            "an empty Strava GPX response is rejected"
        ) {
            _ = try StravaRouteImportResponseV1.validate(
                gpx: Data(),
                requestedRouteURL: routeURL,
                contentType: "application/gpx+xml",
                cacheControl: "private, no-store",
                providerID: RouteProviderPolicyV1.strava.providerID,
                externalRouteID: routeURL.externalRouteID,
                fetchedAt: fetchedAtText,
                deleteAfter: deleteAfterText,
                now: fetchedAt
            )
        }
        let maximumBody = Data(
            repeating: 0x20,
            count: GPXRouteImporterV1.maximumInputBytes
        )
        _ = try StravaRouteImportResponseV1.validate(
            gpx: maximumBody,
            requestedRouteURL: routeURL,
            contentType: "application/gpx+xml",
            cacheControl: "private, no-store",
            providerID: RouteProviderPolicyV1.strava.providerID,
            externalRouteID: routeURL.externalRouteID,
            fetchedAt: fetchedAtText,
            deleteAfter: deleteAfterText,
            now: fetchedAt
        )
        expectThrows(
            StravaRouteContractError.responseTooLarge,
            "a Strava GPX response one byte over the parser bound is rejected"
        ) {
            _ = try StravaRouteImportResponseV1.validate(
                gpx: maximumBody + Data([0]),
                requestedRouteURL: routeURL,
                contentType: "application/gpx+xml",
                cacheControl: "private, no-store",
                providerID: RouteProviderPolicyV1.strava.providerID,
                externalRouteID: routeURL.externalRouteID,
                fetchedAt: fetchedAtText,
                deleteAfter: deleteAfterText,
                now: fetchedAt
            )
        }
        expectThrows(
            StravaRouteContractError.invalidResponseContract,
            "a mismatched route response cannot be imported"
        ) {
            _ = try StravaRouteImportResponseV1.validate(
                gpx: minimalGPX,
                requestedRouteURL: routeURL,
                contentType: "application/gpx+xml",
                cacheControl: "private, no-store",
                providerID: RouteProviderPolicyV1.strava.providerID,
                externalRouteID: "123",
                fetchedAt: fetchedAtText,
                deleteAfter: deleteAfterText,
                now: fetchedAt
            )
        }

        let routeID = UUID(
            uuidString: "dddddddd-1111-2222-3333-eeeeeeeeeeee"
        )!
        let gpx = Data("""
        <gpx version="1.1" creator="Strava">
          <rte><name>Provider route name</name>
            <rtept lat="1.0000" lon="103.0000"/>
            <rtept lat="1.0005" lon="103.0005"/>
            <rtept lat="1.0010" lon="103.0010"/>
          </rte>
        </gpx>
        """.utf8)
        let archive = try GPXRouteImporterV1.archive(
            data: gpx,
            fallbackName: "Strava route",
            routeID: routeID,
            revision: 3,
            source: .strava(receipt: receipt),
            localeIdentifier: "en_US"
        )
        expect(
            archive.route.provider == RouteProviderPolicyV1.strava &&
                archive.route.sourceReference == routeURL.sourceReference &&
                archive.route.revision == 3 &&
                archive.createdAt == fetchedAt &&
                archive.deleteAfter == deleteAfter &&
                archive.route.steps.first?.instruction == "Follow Strava route",
            "Strava GPX uses the reviewed provider, source, revision, wording, and deadline"
        )
        expectThrows(
            NavigationRouteArchiveError.deletionDateRequired(
                providerID: RouteProviderPolicyV1.strava.providerID
            ),
            "Strava geometry can never enter offline storage without an expiry"
        ) {
            _ = try NavigationRouteArchiveV1.create(
                route: archive.route,
                createdAt: fetchedAt,
                purpose: .offlineNavigation
            )
        }
        expectThrows(
            NavigationRouteArchiveError.retentionExceeded(
                providerID: RouteProviderPolicyV1.strava.providerID
            ),
            "Strava geometry cannot outlive the compiled seven-day maximum"
        ) {
            _ = try NavigationRouteArchiveV1.create(
                route: archive.route,
                createdAt: fetchedAt,
                deleteAfter: deleteAfter.addingTimeInterval(0.001),
                purpose: .offlineNavigation
            )
        }
        expectThrows(
            NavigationRouteArchiveError.expired,
            "a Strava archive stops being usable at the exact seven-day deadline"
        ) {
            try archive.validate(
                purpose: .offlineNavigation,
                now: deleteAfter
            )
        }

        let routeStoreRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "open-bike-strava-archive-transaction-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: routeStoreRoot) }
        let routeStore = NavigationRouteFileStoreV1(
            rootDirectory: routeStoreRoot
        )
        let archiveData = try archive.encoded(
            purpose: .offlineNavigation,
            now: fetchedAt
        )
        _ = try routeStore.install(archiveData, now: fetchedAt)
        let revisionFour = try GPXRouteImporterV1.archive(
            data: gpx,
            fallbackName: "Strava route",
            routeID: routeID,
            revision: 4,
            source: .strava(receipt: receipt),
            localeIdentifier: "en_US"
        )
        enum CompanionWriteFailure: Error { case expected }
        do {
            _ = try routeStore.installAtomically(
                revisionFour.encoded(
                    purpose: .offlineNavigation,
                    now: fetchedAt
                ),
                now: fetchedAt
            ) {
                throw CompanionWriteFailure.expected
            }
            fatalError("FAILED: failed companion metadata must abort replacement")
        } catch CompanionWriteFailure.expected {
            // Expected.
        }
        expect(
            routeStore.records(now: fetchedAt).map(\.archive.revision) == [3],
            "a failed bookmark commit leaves the prior archive revision intact"
        )
        expect(
            routeStore.records(now: deleteAfter).isEmpty &&
                routeStore.expiredRecords(now: deleteAfter).map(
                    \.archive.revision
                ) == [3],
            "expired geometry is unavailable while its exact identity remains inspectable for deletion"
        )
        expect(
            routeStore.pruneInvalidAndExpired(now: deleteAfter) == 1 &&
                routeStore.recordsIncludingExpired().isEmpty,
            "deadline reconciliation removes the retained route bytes"
        )

        let localArchive = try GPXRouteImporterV1.archive(
            data: gpx,
            fallbackName: "local.gpx",
            routeID: UUID(),
            createdAt: fetchedAt,
            localeIdentifier: "en_US"
        )
        let localData = try localArchive.encoded(
            purpose: .offlineNavigation,
            now: fetchedAt
        )
        expect(
            localArchive.deleteAfter == nil &&
                localArchive.route.sourceReference == nil &&
                !String(decoding: localData, as: UTF8.self)
                    .contains("sourceReference"),
            "legacy local GPX archives remain durable and encode without the optional source field"
        )
        try expect(
            try NavigationRouteArchiveV1.decode(
                localData,
                purpose: .offlineNavigation,
                now: fetchedAt
            ) == localArchive,
            "version-one archives without a source reference still decode"
        )

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "open-bike-strava-bookmarks-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StravaRouteReloadBookmarkStoreV1(
            fileURL: root.appendingPathComponent("bookmarks.json")
        )
        let bookmark = try StravaRouteReloadBookmarkV1(
            routeURL: routeURL,
            routeID: routeID,
            lastRevision: 3,
            localAlias: "  My local alias  ",
            createdAt: fetchedAt,
            lastReloadSucceededAt: fetchedAt,
            lastValidationAt: fetchedAt
        )
        try store.upsert(bookmark)
        let loaded = try store.bookmark(routeID: routeID)
        expect(
            loaded?.localAlias == "My local alias" &&
                loaded?.externalRouteID == routeURL.externalRouteID &&
                loaded?.nextRevision == 4,
            "the reload bookmark retains only canonical user/local identity"
        )
        let storedText = try String(
            contentsOf: store.fileURL,
            encoding: .utf8
        )
        expect(
            !storedText.contains("Provider route name") &&
                !storedText.contains("Strava start") &&
                !storedText.contains("distanceMeters") &&
                !storedText.contains("points"),
            "the reload bookmark cannot retain API-derived route content"
        )
        let attempted = try bookmark.updating(
            lastReloadAttemptAt: .some(deleteAfter.addingTimeInterval(-60))
        )
        try store.upsert(attempted)
        try expect(
            try store.bookmark(routeID: routeID) == attempted &&
                attempted != bookmark,
            "reload continues with the exact bookmark produced by its attempt write"
        )
        let updated = try attempted.updating(
            lastRevision: 4,
            lastReloadAttemptAt: .some(deleteAfter),
            lastReloadSucceededAt: .some(deleteAfter),
            lastValidationAt: .some(deleteAfter),
            lastErrorAt: .some(nil)
        )
        try store.upsert(updated)
        try expect(
            try store.bookmark(externalRouteID: routeURL.externalRouteID) == updated,
            "a successful reload updates the same route identity and revision"
        )
        try expect(
            try store.purge() == 1 && (try store.bookmarks()).isEmpty,
            "provider purge removes the retained reload reference"
        )
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
        expect(
            WatchDirectBLEProtocolV1.capabilityClientVersion == 23 &&
                WatchDirectBLEProtocolV1.scopedControllerFeature == 1 << 14 &&
                WatchDirectBLEProtocolV1.rideAutomationFeature == 1 << 15 &&
                WatchDirectBLEProtocolV1.gpsPositionQualityV1Feature == 1 << 17 &&
                WatchDirectBLEProtocolV1.rideDeliveryAcknowledgementFeature ==
                    1 << 22 &&
                WatchDirectBLEProtocolV1.watchGPSMotionEvidenceV1Feature ==
                    1 << 25,
            "Watch requests reliable ride delivery and Watch GPS motion evidence without moving existing capabilities"
        )
        let flags = WatchDirectBLEProtocolV1.scopedControllerFeature |
            WatchDirectBLEProtocolV1.workoutTelemetryFeature |
            WatchDirectBLEProtocolV1.rideAutomationFeature |
            WatchDirectBLEProtocolV1.gpsPositionQualityV1Feature |
            WatchDirectBLEProtocolV1.rideDeliveryAcknowledgementFeature |
            WatchDirectBLEProtocolV1.watchGPSMotionEvidenceV1Feature
        cap2.append(UInt8(flags & 0xFF))
        cap2.append(UInt8((flags >> 8) & 0xFF))
        cap2.append(UInt8((flags >> 16) & 0xFF))
        cap2.append(UInt8((flags >> 24) & 0xFF))
        let capabilities = WatchDeviceCapabilitiesV1.decode(cap2)
        expect(
            capabilities?.supportsScopedController == true &&
                capabilities?.supportsWorkoutTelemetry == true &&
                capabilities?.supportsRideAutomation == true &&
                capabilities?.supportsGPSPositionQualityV1 == true &&
                capabilities?.supportsRideDeliveryAcknowledgement == true &&
                capabilities?.supportsWatchGPSMotionEvidenceV1 == true,
            "Watch recognizes direct-controller, workout, ride-automation, GPS-quality, delivery-ack, and Watch-motion capabilities"
        )
        let deliveryCommandID = UUID(
            uuidString: "00112233-4455-6677-8899-aabbccddeeff"
        )!
        let deliveryEnvelope = RideBLEApplicationCommandEnvelopeV1(
            commandType: .workoutState,
            memberIndex: 1,
            memberCount: 3,
            commandID: deliveryCommandID,
            stateGeneration: 0x1234_5678,
            payload: Data([0xAA, 0xBB])
        )
        let deliveryBytes = deliveryEnvelope.encoded()
        expect(
            deliveryBytes?.map { String(format: "%02x", $0) }.joined() ==
                RideBLEGeneratedProtocolV1.applicationCommandGoldenHex &&
                deliveryBytes.flatMap(
                    RideBLEApplicationCommandEnvelopeV1.decode
                ) == deliveryEnvelope,
            "ride command envelope matches the shared golden vector"
        )
        let deliveryAck = RideBLEApplicationAcknowledgementV1(
            commandType: .workoutState,
            result: .success,
            commandID: deliveryCommandID,
            stateGeneration: 0x1234_5678,
            leaseGeneration: 9
        )
        expect(
            deliveryAck.encoded().map {
                String(format: "%02x", $0)
            }.joined() ==
                RideBLEGeneratedProtocolV1
                    .applicationAcknowledgementGoldenHex &&
                RideBLEApplicationAcknowledgementV1.decode(
                    deliveryAck.encoded()
                ) == deliveryAck,
            "ride acknowledgement matches the shared golden vector"
        )
        let deliveryIdentity = RideBLEApplicationPendingIdentityV1(
            commandType: .workoutState,
            commandID: deliveryCommandID,
            stateGeneration: 0x1234_5678
        )
        expect(
            RideBLEApplicationAcknowledgementPolicyV1.disposition(
                pending: deliveryIdentity,
                acknowledgement: deliveryAck
            ) == .completed(result: .success),
            "a matching application acknowledgement completes one logical group"
        )
        expect(
            RideBLEApplicationAcknowledgementPolicyV1.disposition(
                pending: deliveryIdentity,
                acknowledgement: .init(
                    commandType: .workoutState,
                    result: .success,
                    commandID: UUID(),
                    stateGeneration: 0x1234_5678,
                    leaseGeneration: 9
                )
            ) == .ignored,
            "a delayed acknowledgement for another command cannot complete current state"
        )
        expect(
            RideBLEApplicationAcknowledgementPolicyV1.disposition(
                pending: deliveryIdentity,
                acknowledgement: .init(
                    commandType: .workoutState,
                    result: .success,
                    commandID: deliveryCommandID,
                    stateGeneration: 0x1234_5679,
                    leaseGeneration: 9
                )
            ) == .ignored,
            "a reordered acknowledgement for another state generation is ignored"
        )
        expect(
            RideBLEApplicationAcknowledgementPolicyV1.disposition(
                pending: deliveryIdentity,
                acknowledgement: .init(
                    commandType: .workoutState,
                    result: .resourceRejected,
                    commandID: deliveryCommandID,
                    stateGeneration: 0x1234_5678,
                    leaseGeneration: 9
                )
            ) == .rejected(result: .resourceRejected),
            "firmware resource rejection remains a typed application outcome"
        )
        expect(
            RideBLEApplicationAcknowledgementPolicyV1.disposition(
                pending: deliveryIdentity,
                acknowledgement: .init(
                    commandType: .workoutState,
                    result: .success,
                    commandID: deliveryCommandID,
                    stateGeneration: 0x1234_5678,
                    leaseGeneration: 0
                )
            ) == .invalidLeaseGeneration,
            "an acknowledgement without authenticated lease identity fails closed"
        )
        expect(
            RideBLEApplicationRetryPolicyV1.timeoutAction(
                completedRetries: 0
            ) == .retry &&
                RideBLEApplicationRetryPolicyV1.timeoutAction(
                    completedRetries: 1
                ) == .recoverTransport,
            "lost application acknowledgements receive one bounded retry"
        )
        var malformed = cap2
        malformed.append(contentsOf: [1, 4, 0, 0, 0])
        expect(
            WatchDeviceCapabilitiesV1.decode(malformed) == nil,
            "malformed capability TLVs are rejected"
        )
        expect(
            WatchNavigationNotificationV1.decode(cap2) ==
                .capabilities(capabilities!),
            "a protected CAP2 notification advances Watch setup"
        )
        expect(
            WatchNavigationNotificationV1.decode(Data("DREQ".utf8) +
                Data(repeating: 0, count: 6)) == .ignoredDeviceRequest,
            "an owner-only destination request cannot tear down a Watch ride"
        )
        expect(
            WatchNavigationNotificationV1.decode(Data("WREQ".utf8)) ==
                .ignoredDeviceRequest,
            "an owner-only workout request cannot tear down a Watch ride"
        )
        expect(
            WatchNavigationNotificationV1.decode(Data("WREQ\0".utf8)) ==
                .invalidCapabilities,
            "a malformed owner-only workout request still fails closed"
        )
        expect(
            WatchNavigationNotificationV1.decode(Data("CAP2".utf8)) ==
                .invalidCapabilities,
            "a malformed capability response still fails closed"
        )
        let rideFrame = Data((0..<52).map(UInt8.init))
        expect(
            WatchRideAutomationTransportV1.outbound(
                frame: rideFrame,
                nativeCharacteristicAvailable: true
            ) == .init(target: .rideAutomation, payload: rideFrame),
            "Watch RAUT prefers the native channel 7 characteristic"
        )
        var rideFallback = Data("RAUT".utf8)
        rideFallback.append(rideFrame)
        expect(
            WatchRideAutomationTransportV1.outbound(
                frame: rideFrame,
                nativeCharacteristicAvailable: false
            ) == .init(target: .navigation, payload: rideFallback) &&
                WatchRideAutomationTransportV1.decodeNavigationFallback(
                    rideFallback
                ) == rideFrame,
            "cached GATT tables use the bounded RAUT navigation fallback"
        )
        expect(
            WatchRideAutomationTransportV1.decodeNavigationFallback(
                Data(rideFallback.dropLast())
            ) == nil &&
                WatchRideAutomationTransportV1.outbound(
                    frame: Data(rideFrame.dropLast()),
                    nativeCharacteristicAvailable: false
                ) == nil,
            "RAUT fallback rejects every noncanonical frame size"
        )
        expect(
            WatchNavigationNotificationV1.decode(Data("NOPE".utf8)) ==
                .invalidCapabilities,
            "an unknown navigation notification fails closed"
        )

        var demand = WatchRideDemandStateV1()
        demand.setNavigationActive(true)
        demand.beginNavigationRelease()
        expect(
            demand.requiresConnection &&
                demand.navigationReleasePending &&
                !demand.navigationActive,
            "a disconnected navigation clear retains BLE demand"
        )
        demand.setWorkoutActive(true)
        demand.completePendingReleases()
        expect(
            demand.requiresConnection &&
                demand.workoutActive &&
                !demand.navigationReleasePending,
            "draining a navigation clear preserves independent workout demand"
        )
        demand.beginWorkoutRelease()
        expect(
            demand.requiresConnection && demand.requiresWorkoutChannel &&
                demand.workoutReleasePending,
            "a disconnected workout clear retains its channel and BLE demand"
        )
        demand.completePendingReleases()
        expect(
            !demand.requiresConnection && !demand.requiresWorkoutChannel,
            "the direct link can stop only after every clear has drained"
        )
        demand.beginNavigationRelease()
        demand.setNavigationActive(true)
        expect(
            demand.navigationActive && !demand.navigationReleasePending,
            "new navigation supersedes an undelivered stale clear"
        )

        func group(
            _ payloads: [UInt8],
            priority: RideBLECommandPriorityV1,
            disposition: RideBLECommandDispositionV1 = .replaceable,
            key: String? = nil
        ) -> WatchBLEOutboundGroupV1 {
            WatchBLEOutboundGroupV1(
                connectionGeneration: 1,
                stateGeneration: UInt32(payloads.first ?? 0),
                priority: priority,
                disposition: disposition,
                coalescingKey: key,
                writes: payloads.map {
                    .init(target: .navigation, payload: Data([$0]))
                }
            )
        }
        var queue = WatchBLEOutboundQueueV1(
            capacity: 6,
            reservedCriticalFrames: 3
        )
        expect(queue.enqueue(group(
            [1], priority: .livePosition, key: "route"
        )).admitted, "route is queued")
        expect(queue.enqueue(group(
            [2], priority: .livePosition, key: "gps"
        )).admitted, "GPS is queued")
        expect(queue.enqueue(group(
            [3], priority: .livePosition, key: "gps"
        )).admitted, "new GPS coalesces atomically")
        expect(queue.enqueue(group(
            [4], priority: .navigationBoundary, key: "maneuver"
        )).admitted, "latest maneuver is queued")
        expect(
            queue.dequeueGroup()?.writes.first?.payload == Data([4]) &&
                queue.dequeueGroup()?.writes.first?.payload == Data([1]) &&
                queue.dequeueGroup()?.writes.first?.payload == Data([3]),
            "group priority is stable and replaceable state coalesces"
        )

        for capacity in 1...5 {
            var boundaryQueue = WatchBLEOutboundQueueV1(
                capacity: capacity,
                reservedCriticalFrames: min(3, capacity)
            )
            let admission = boundaryQueue.enqueue(group(
                [10, 11, 12],
                priority: .terminalWorkout,
                disposition: .critical,
                key: "workout"
            ))
            expect(
                admission.admitted == (capacity >= 3) &&
                    boundaryQueue.pendingFrameCount ==
                        (capacity >= 3 ? 3 : 0),
                "a three-frame terminal group is admitted entirely or not at capacity \(capacity)"
            )
        }
        var saturated = WatchBLEOutboundQueueV1(
            capacity: 5,
            reservedCriticalFrames: 2
        )
        expect(
            saturated.enqueue(group(
                [20, 21, 22], priority: .livePosition, key: "bulk"
            )).admitted &&
                saturated.enqueue(group(
                    [23], priority: .diagnostics, key: "extra"
                )) == .rejectedReplaceable,
            "replaceable traffic cannot consume critical reserve"
        )
        let criticalAdmission = saturated.enqueue(group(
            [30, 31, 32],
            priority: .control,
            disposition: .critical,
            key: "clear"
        ))
        expect(
            criticalAdmission.admitted &&
                saturated.pendingFrameCount == 3 &&
                saturated.dequeueGroup()?.writes.map(\.payload) == [
                    Data([30]), Data([31]), Data([32]),
                ],
            "a critical group atomically evicts replaceable saturation"
        )
        var boundaryRetention = WatchBLEOutboundQueueV1(
            capacity: 4,
            reservedCriticalFrames: 2
        )
        expect(
            boundaryRetention.enqueue(group(
                [40],
                priority: .terminalWorkout,
                disposition: .critical,
                key: "workout"
            )).admitted &&
                boundaryRetention.enqueue(group(
                    [41],
                    priority: .livePosition,
                    key: "workout"
                )) == .rejectedReplaceable &&
                boundaryRetention.dequeueGroup()?.writes.first?.payload ==
                    Data([40]),
            "replaceable state cannot supersede a queued critical boundary"
        )

        var byteBounded = WatchBLEOutboundQueueV1(
            capacity: 4,
            reservedCriticalFrames: 1,
            byteCapacity: 8,
            reservedCriticalBytes: 4
        )
        let replaceableBytes = WatchBLEOutboundGroupV1(
            connectionGeneration: 1,
            stateGeneration: 1,
            priority: .livePosition,
            disposition: .replaceable,
            coalescingKey: "byte-state",
            writes: [.init(
                target: .navigation,
                payload: Data(repeating: 1, count: 4)
            )]
        )
        let criticalBytes = WatchBLEOutboundGroupV1(
            connectionGeneration: 1,
            stateGeneration: 2,
            priority: .control,
            disposition: .critical,
            coalescingKey: "byte-boundary",
            writes: [.init(
                target: .navigation,
                payload: Data(repeating: 2, count: 4)
            )]
        )
        expect(
            byteBounded.enqueue(replaceableBytes).admitted &&
                byteBounded.pendingByteCount == 4 &&
                byteBounded.enqueue(criticalBytes).admitted &&
                byteBounded.pendingByteCount == 8 &&
                byteBounded.metrics.highWaterBytes == 8,
            "queue byte ceiling preserves an explicit critical reserve"
        )
        let oversizedFrame = WatchBLEOutboundGroupV1(
            connectionGeneration: 1,
            stateGeneration: 3,
            priority: .livePosition,
            disposition: .replaceable,
            writes: [.init(
                target: .navigation,
                payload: Data(
                    repeating: 3,
                    count: WatchBLEOutboundQueueV1.maximumFrameBytes + 1
                )
            )]
        )
        expect(
            byteBounded.enqueue(oversizedFrame) == .rejectedReplaceable &&
                byteBounded.pendingByteCount == 8,
            "an oversized frame is rejected without disturbing admitted groups"
        )

        let location = sample(latitude: 1, longitude: 2, altitude: 3)
        expect(
            WatchRidePacketEncoderV1.gps(
                location,
                snapshot: nil
            ).count == 30,
            "Watch GPS payload matches the firmware binary schema"
        )
        let qualityPacket = WatchRidePacketEncoderV1.gps(
            location,
            snapshot: nil,
            includeRideDetectionQuality: true,
            now: location.timestamp.addingTimeInterval(0.75)
        )
        expect(
            qualityPacket.count == 36 && qualityPacket[30] == 1 &&
                qualityPacket[31] == 3,
            "Watch GPS quality payload matches the negotiated v1 schema"
        )
        let delayedQualityPacket =
            WatchRidePacketEncoderV1.refreshingQualityAge(
                in: qualityPacket,
                sampleTimestamp: location.timestamp,
                now: location.timestamp.addingTimeInterval(2)
            )
        expect(
            delayedQualityPacket[34] == 0xD0 &&
                delayedQualityPacket[35] == 0x07,
            "Watch GPS quality accounts for time spent in the BLE queue"
        )
        let missingSpeedSample = NavigationLocationSampleV1(
            coordinate: location.coordinate,
            horizontalAccuracyMeters: location.horizontalAccuracyMeters,
            courseDegrees: location.courseDegrees,
            speedMetersPerSecond: -1,
            altitudeMeters: location.altitudeMeters,
            timestamp: location.timestamp
        )
        let missingSpeedQuality = WatchRidePacketEncoderV1.gps(
            missingSpeedSample,
            snapshot: nil,
            includeRideDetectionQuality: true,
            now: location.timestamp
        )
        expect(
            missingSpeedQuality[31] == 2,
            "Watch quality without measured speed never claims a detector-ready fix"
        )
        let invalidCourse = NavigationLocationSampleV1(
            coordinate: location.coordinate,
            horizontalAccuracyMeters: location.horizontalAccuracyMeters,
            courseDegrees: -1,
            speedMetersPerSecond: location.speedMetersPerSecond,
            altitudeMeters: location.altitudeMeters,
            timestamp: location.timestamp
        )
        let invalidCoursePacket = WatchRidePacketEncoderV1.gps(
            invalidCourse,
            snapshot: nil
        )
        expect(
            invalidCoursePacket[8] == 0xFF &&
                invalidCoursePacket[9] == 0xFF,
            "Watch GPS uses the version-11 explicit invalid-heading sentinel"
        )

        let diagnostic = WatchBLETransportDiagnosticEventV1(
            attemptID: UUID(),
            sequence: 1,
            kind: .attTimeout,
            phase: RideBLETransportPhaseV1.recovering.rawValue,
            reason: RideBLETransportFailureReasonV1.attTimeout.rawValue,
            connectionGeneration: 4,
            queueDepth: 3,
            queueHighWater: 8,
            queueBytes: 512,
            queueHighWaterBytes: 2_048,
            replacedGroups: 2,
            rejectedGroups: 1,
            uptimeMs: 12_345,
            latencyMs: 8_000
        )
        let diagnosticBatch = WatchBLETransportDiagnosticBatchV1(
            events: [diagnostic]
        )
        try expect(
            WatchBLETransportDiagnosticBatchV1.decode(
                try diagnosticBatch.encoded()
            ) == diagnosticBatch,
            "Watch transport diagnostics round-trip without ride payload data"
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

        let metadata = try WatchDeviceMetadataV1(
            name: "Chris’s Apple Watch",
            localizedModel: "Apple Watch Ultra 2",
            systemName: "watchOS",
            systemVersion: "26.0"
        )
        try expect(
            try WatchDeviceMetadataV1.decode(metadata.encoded()) == metadata,
            "Watch display metadata round-trips"
        )
        expectThrows(
            WatchControllerContractError.invalidEnvelope,
            "empty Watch names are rejected"
        ) {
            _ = try WatchDeviceMetadataV1(
                name: "  ",
                localizedModel: "Apple Watch",
                systemName: "watchOS",
                systemVersion: "26.0"
            )
        }
        expectThrows(
            WatchControllerContractError.invalidEnvelope,
            "oversized Watch names are rejected"
        ) {
            _ = try WatchDeviceMetadataV1(
                name: String(
                    repeating: "a",
                    count: WatchDeviceMetadataV1.maximumDisplayValueBytes + 1
                ),
                localizedModel: "Apple Watch",
                systemName: "watchOS",
                systemVersion: "26.0"
            )
        }

        let selectedBikeComputer = try WatchSelectedBikeComputerV1(
            revision: 7,
            deviceID: deviceID.uppercased()
        )
        try expect(
            try WatchSelectedBikeComputerV1.decode(
                selectedBikeComputer.encoded()
            ) == selectedBikeComputer &&
                selectedBikeComputer.selects(credential),
            "the Watch targets the exact normalized iPhone-selected device"
        )
        let otherCredential = try WatchControllerCredentialV1(
            deviceID: "ffeeddccbbaa99887766554433221100",
            controllerID: Data(repeating: 0x22, count: 16),
            key: Data(repeating: 0x33, count: 32)
        )
        expect(
            !selectedBikeComputer.selects(otherCredential),
            "another enrolled Bike Computer cannot be selected implicitly"
        )
        let clearedSelection = try WatchSelectedBikeComputerV1(
            revision: 8,
            deviceID: nil
        )
        expect(
            !clearedSelection.selects(credential),
            "an explicit cleared selection is a fail-closed tombstone"
        )
        let preparationRequest = try WatchDirectRidePreparationRequestV1(
            requestID: UUID(
                uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )!,
            preparationID: UUID(
                uuidString: "11111111-aaaa-bbbb-cccc-222222222222"
            )!,
            operation: .prepare,
            deviceID: deviceID.uppercased()
        )
        try expect(
            try WatchDirectRidePreparationRequestV1.decode(
                preparationRequest.encoded()
            ) == preparationRequest,
            "Watch-direct preparation requests are exact and versioned"
        )
        let preparationIntent = try WatchDirectRidePreparationIntentV1(
            preparationID: preparationRequest.preparationID,
            operation: .prepare,
            deviceID: deviceID.uppercased()
        )
        let restoredPreparationIntent = try
            WatchDirectRidePreparationIntentV1.decode(
                preparationIntent.encoded()
            )
        let firstPreparationAttempt = try restoredPreparationIntent.request(
            requestID: UUID(
                uuidString: "10000000-0000-0000-0000-000000000001"
            )!
        )
        let retryPreparationAttempt = try restoredPreparationIntent.request(
            requestID: UUID(
                uuidString: "10000000-0000-0000-0000-000000000002"
            )!
        )
        expect(
            restoredPreparationIntent == preparationIntent &&
                firstPreparationAttempt.requestID !=
                    retryPreparationAttempt.requestID &&
                firstPreparationAttempt.preparationID ==
                    retryPreparationAttempt.preparationID &&
                firstPreparationAttempt.deviceID == deviceID,
            "Watch preparation retries preserve their logical identity"
        )
        var restoredPreparationGate =
            WatchDirectRidePreparationRestorationGateV1(
                restoredOperation: .prepare
            )
        expect(
            restoredPreparationGate.complete(
                hasRecoveredDemand: true
            ) == .retain &&
                restoredPreparationGate.complete(
                    hasRecoveredDemand: false
                ) == .none,
            "a restored active ride retains preparation exactly once"
        )
        var abandonedPreparationGate =
            WatchDirectRidePreparationRestorationGateV1(
                restoredOperation: .prepare
            )
        expect(
            abandonedPreparationGate.complete(
                hasRecoveredDemand: false
            ) == .release,
            "a relaunch without recovered ride demand releases preparation"
        )
        var restoredReleaseGate =
            WatchDirectRidePreparationRestorationGateV1(
                restoredOperation: .release
            )
        expect(
            restoredReleaseGate.complete(
                hasRecoveredDemand: false
            ) == .none,
            "an already durable release is not reclassified as preparation"
        )
        expect(
            WatchDirectRidePreparationRetryPolicyV1.delaySeconds(
                afterAttempt: 1
            ) == 1 &&
                WatchDirectRidePreparationRetryPolicyV1.delaySeconds(
                    afterAttempt: 6
                ) == 30 &&
                WatchDirectRidePreparationRetryPolicyV1.delaySeconds(
                    afterAttempt: 100
                ) == 30,
            "Watch preparation retry backoff is bounded"
        )
        let preparationResponse = WatchDirectRidePreparationResponseV1(
            requestID: preparationRequest.requestID,
            accepted: false,
            errorCode: "phone_navigation_active"
        )
        try expect(
            try WatchDirectRidePreparationResponseV1.decode(
                preparationResponse.encoded()
            ) == preparationResponse,
            "Watch-direct preparation responses bind the request identity"
        )
        expect(
            WatchDirectRidePreparationPolicyV1.rejectionCode(
                requestedDeviceID: deviceID,
                selectedDeviceID: deviceID,
                phoneNavigationActive: false,
                transferActive: false,
                administrationActive: false
            ) == nil,
            "an idle iPhone may yield the selected Bicino"
        )
        expect(
            WatchDirectRidePreparationPolicyV1.rejectionCode(
                requestedDeviceID: deviceID,
                selectedDeviceID: deviceID,
                phoneNavigationActive: true,
                transferActive: false,
                administrationActive: false
            ) == "phone_navigation_active",
            "active iPhone navigation cannot be yielded to Watch"
        )
        expect(
            WatchDirectRidePreparationPolicyV1.rejectionCode(
                requestedDeviceID: deviceID,
                selectedDeviceID: otherCredential.deviceID,
                phoneNavigationActive: false,
                transferActive: false,
                administrationActive: false
            ) == "different_device",
            "a preparation request cannot retarget the iPhone"
        )
        let currentRelease = try WatchDirectRidePreparationRequestV1(
            preparationID: preparationRequest.preparationID,
            operation: .release,
            deviceID: deviceID
        )
        expect(
            WatchDirectRidePreparationPolicyV1.releaseMatches(
                preparedDeviceID: deviceID,
                preparedPreparationID: preparationRequest.preparationID,
                request: currentRelease
            ),
            "the matching durable release resumes the iPhone"
        )
        let staleRelease = try WatchDirectRidePreparationRequestV1(
            preparationID: UUID(),
            operation: .release,
            deviceID: deviceID
        )
        expect(
            !WatchDirectRidePreparationPolicyV1.releaseMatches(
                preparedDeviceID: deviceID,
                preparedPreparationID: preparationRequest.preparationID,
                request: staleRelease
            ),
            "a delayed release from an older ride cannot cancel a new yield"
        )

        let availableWatch = WatchControllerAvailabilityV1(
            isSupported: true,
            isActivated: true,
            isPaired: true,
            isWatchAppInstalled: true,
            isReachable: true
        )
        expect(
            WatchControllerAutomaticEnrollmentPolicyV1.shouldStart(
                firmwareSupportsScopedController: true,
                deviceConnectedAndAuthenticated: true,
                controllerStatusKnown: true,
                hasController: false,
                operationInFlight: false,
                availability: availableWatch
            ),
            "automatic enrollment starts only after all trust boundaries are ready"
        )
        expect(
            !WatchControllerAutomaticEnrollmentPolicyV1.shouldStart(
                firmwareSupportsScopedController: true,
                deviceConnectedAndAuthenticated: true,
                controllerStatusKnown: false,
                hasController: false,
                operationInFlight: false,
                availability: availableWatch
            ),
            "automatic enrollment waits for authoritative firmware status"
        )
        expect(
            !WatchControllerAutomaticEnrollmentPolicyV1.shouldStart(
                firmwareSupportsScopedController: true,
                deviceConnectedAndAuthenticated: true,
                controllerStatusKnown: true,
                hasController: true,
                operationInFlight: false,
                availability: availableWatch
            ),
            "automatic enrollment never overwrites an existing controller"
        )
        var unreachableWatch = availableWatch
        unreachableWatch.isReachable = false
        expect(
            !WatchControllerAutomaticEnrollmentPolicyV1.shouldStart(
                firmwareSupportsScopedController: true,
                deviceConnectedAndAuthenticated: true,
                controllerStatusKnown: true,
                hasController: false,
                operationInFlight: false,
                availability: unreachableWatch
            ),
            "automatic enrollment waits for a live Watch app"
        )
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

        var skippedFixRuntime = NavigationRuntimeV1()
        _ = try skippedFixRuntime.start(
            route: route,
            contentHash: "fixture",
            mode: .offline,
            initialLocation: sample(latitude: 0, longitude: 0)
        )
        let skippedFixSnapshot = try skippedFixRuntime.process(
            sample(
                latitude: 0,
                longitude: 0.0014,
                timestamp: 1_700_000_001
            )
        )
        expect(
            skippedFixSnapshot.currentStepIndex == 1,
            "an on-route GPS gap beyond the arrival band advances the maneuver"
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
        expect(
            WatchRouteSyncMessageV1.isInstallTransfer(
                message.propertyList,
                matching: identity
            ),
            "the exact queued install is cancellable"
        )
        expect(
            !WatchRouteSyncMessageV1.isInstallTransfer(
                WatchRouteSyncMessageV1(
                    operation: .delete,
                    identity: identity
                ).propertyList,
                matching: identity
            ),
            "a queued deletion cannot be cancelled as an install"
        )
        expect(
            !WatchRouteSyncMessageV1.isInstallTransfer(
                message.propertyList,
                matching: WatchRouteIdentityV1(
                    routeID: UUID(),
                    revision: identity.revision,
                    contentHash: identity.contentHash
                )
            ),
            "route cancellation is bound to the exact identity"
        )
        let renamedEntry = try WatchRouteDisplayNameV1(
            identity: identity,
            name: "  Morning Loop  "
        )
        let displayNames = try WatchRouteDisplayNamesEnvelopeV1(
            revision: 1,
            entries: [renamedEntry]
        )
        try expect(
            try WatchRouteDisplayNamesEnvelopeV1.decode(
                displayNames.encoded()
            ).entries.first?.name == "Morning Loop",
            "exact route display names round-trip in canonical form"
        )
        expectThrows(
            WatchRouteDisplayNameContractErrorV1.duplicateIdentity,
            "a route display-name revision cannot equivocate"
        ) {
            _ = try WatchRouteDisplayNamesEnvelopeV1(
                revision: 2,
                entries: [renamedEntry, renamedEntry]
            )
        }
        switch WatchRouteFilePayloadV1.validate(
            request: message,
            resourceByteCount: data.count,
            data: data
        ) {
        case .success(let validated):
            expect(validated == data, "an exact queued route file is accepted")
        case .failure:
            expect(false, "an exact queued route file must not be rejected")
        }
        switch WatchRouteFilePayloadV1.validate(
            request: message,
            resourceByteCount: data.count,
            data: nil
        ) {
        case .failure(.fileRead):
            break
        default:
            expect(false, "a valid route identity receives a file-read rejection")
        }
        switch WatchRouteFilePayloadV1.validate(
            request: message,
            resourceByteCount: data.count - 1,
            data: Data(data.dropLast())
        ) {
        case .failure(.byteCount):
            break
        default:
            expect(false, "a truncated queued route receives a byte-count rejection")
        }
        expect(
            WatchRouteAcknowledgementReconciliationV1.preservesReadyReceipt(
                hasReadyReceipt: true,
                isPendingDeletion: false
            ) &&
                !WatchRouteAcknowledgementReconciliationV1
                    .preservesReadyReceipt(
                        hasReadyReceipt: true,
                        isPendingDeletion: true
                    ),
            "a late install failure cannot downgrade Ready, but deletion failures remain visible"
        )
        let maximumRevisionMessage = WatchRouteSyncMessageV1(
            operation: .delete,
            identity: WatchRouteIdentityV1(
                routeID: identity.routeID,
                revision: .max,
                contentHash: identity.contentHash
            )
        )
        expect(
            WatchRouteSyncMessageV1(
                propertyList: maximumRevisionMessage.propertyList
            ) == maximumRevisionMessage,
            "route revisions remain fixed-width across 32-bit Watch decoding"
        )
        var overflowingRevision = maximumRevisionMessage.propertyList
        overflowingRevision["bicino.route.revision"] = NSNumber(
            value: UInt64(UInt32.max) + 1
        )
        expect(
            WatchRouteSyncMessageV1(propertyList: overflowingRevision) == nil,
            "route revisions above UInt32 remain rejected"
        )
        let immediate = WatchRouteImmediateTransferV1.message(
            install: message,
            archiveData: data
        )
        let decodedImmediate = immediate.flatMap {
            WatchRouteImmediateTransferV1.decode($0)
        }
        expect(
            decodedImmediate?.install == message &&
                decodedImmediate?.archiveData == data,
            "reachable-Watch route messages bind metadata to exact bytes"
        )
        var mismatchedImmediate = immediate ?? [:]
        mismatchedImmediate["bicino.route.archive"] = data + Data([0])
        expect(
            WatchRouteImmediateTransferV1.decode(mismatchedImmediate) == nil,
            "reachable-Watch route messages reject byte-count mismatches"
        )
        expect(
            WatchRouteImmediateTransferV1.message(
                install: message,
                archiveData: Data(
                    repeating: 0,
                    count: WatchRouteImmediateTransferV1
                        .maximumEncodedByteCount + 1
                )
            ) == nil,
            "large route archives stay on the durable file-transfer path"
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

        _ = try boundedStore.install(
            try secondArchive.encoded(
                purpose: .offlineNavigation,
                now: now
            ),
            now: now,
            evictingOldestUnprotected: []
        )
        expect(
            boundedStore.records(now: now).map(\.archive.routeID) ==
                [secondRoute.id],
            "Watch capacity evicts the deterministic oldest unused route"
        )

        let thirdRoute = fixtureRoute(
            provider: RouteProviderPolicyV1.importedGPX,
            routeID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
        )
        let thirdArchive = try NavigationRouteArchiveV1.create(
            route: thirdRoute,
            createdAt: now.addingTimeInterval(1),
            purpose: .offlineNavigation
        )
        expectThrows(
            NavigationRouteFileStoreError.capacityExceeded,
            "an active Watch route remains pinned when capacity is full"
        ) {
            _ = try boundedStore.install(
                try thirdArchive.encoded(
                    purpose: .offlineNavigation,
                    now: now.addingTimeInterval(1)
                ),
                now: now.addingTimeInterval(1),
                evictingOldestUnprotected: [
                    WatchRouteIdentityV1(archive: secondArchive)
                ]
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
