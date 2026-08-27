import Foundation

@main
@MainActor
enum WatchOfflineNavigationTests {
    static func main() throws {
        try testActiveRoutePinAndDeferredDeletion()
        try testNavigationJournalRoundTripAndValidation()
        try testExpiryAndDowngradeFailClosed()
        try testStravaStartWindowAndActiveExpiry()
        try testEvictionReportsExactIdentity()
        print("WatchOfflineNavigationTests passed")
    }

    private static func testStravaStartWindowAndActiveExpiry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "watch-strava-expiry-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "watch-strava-expiry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let deadline = createdAt.addingTimeInterval(604_800)
        var currentTime = createdAt
        let store = NavigationRouteFileStoreV1(
            rootDirectory: root,
            limits: .watch
        )
        let library = WatchRouteLibrary(
            store: store,
            now: { currentTime },
            defaults: defaults
        )
        let strava = try archive(
            revision: 1,
            now: createdAt,
            deleteAfter: deadline,
            provider: RouteProviderPolicyV1.strava,
            sourceReference: RouteSourceReferenceV1(
                providerID: RouteProviderPolicyV1.strava.providerID,
                externalRouteID: "3009840108578231836",
                canonicalURL:
                    "https://www.strava.com/routes/3009840108578231836"
            )
        )
        let identity = WatchRouteIdentityV1(archive: strava)
        _ = try library.install(
            strava.encoded(purpose: .offlineNavigation, now: createdAt),
            expectedIdentity: identity
        )

        currentTime = deadline.addingTimeInterval(
            -WatchRouteLibrary.minimumRemainingValidityForNewNavigation + 1
        )
        expectThrows(
            WatchRouteLibraryError.nearExpiry,
            "Watch requires a reload before starting a near-expiry Strava route"
        ) {
            _ = try library.record(routeID: strava.routeID)
        }

        currentTime = createdAt
        _ = try library.activate(identity)
        var expiredIdentity: WatchRouteIdentityV1?
        library.onRouteExpired = { identity in
            expiredIdentity = identity
            library.deactivate(identity)
        }
        currentTime = deadline
        library.reload()
        expect(
            expiredIdentity == identity &&
                library.activeIdentity == nil &&
                library.pendingDeletionIdentity == nil &&
                library.routes.isEmpty &&
                store.recordsIncludingExpired().isEmpty,
            "hard expiry notifies navigation and removes active Watch geometry"
        )
    }

    private static func testEvictionReportsExactIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "watch-route-eviction-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "watch-route-eviction-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let library = WatchRouteLibrary(
            store: NavigationRouteFileStoreV1(
                rootDirectory: root,
                limits: NavigationRouteFileStoreLimitsV1(
                    maximumArchiveCount: 1,
                    maximumTotalEncodedBytes: 4 * 1_024 * 1_024
                )
            ),
            now: { now },
            defaults: defaults
        )
        let first = try archive(revision: 1, now: now)
        _ = try library.install(
            first.encoded(purpose: .offlineNavigation, now: now),
            expectedIdentity: WatchRouteIdentityV1(archive: first)
        )
        let second = try archive(
            routeID: UUID(
                uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            )!,
            revision: 1,
            now: now.addingTimeInterval(1)
        )
        let result = try library.install(
            second.encoded(
                purpose: .offlineNavigation,
                now: now.addingTimeInterval(1)
            ),
            expectedIdentity: WatchRouteIdentityV1(archive: second)
        )
        expect(
            result.evictedIdentities == [WatchRouteIdentityV1(archive: first)],
            "Watch eviction reports the exact receipt the iPhone must clear"
        )
    }

    private static func testExpiryAndDowngradeFailClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "watch-route-expiry-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "watch-route-expiry-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        var currentTime = createdAt
        let store = NavigationRouteFileStoreV1(
            rootDirectory: root,
            limits: .watch
        )
        let library = WatchRouteLibrary(
            store: store,
            now: { currentTime },
            defaults: defaults
        )
        let retained = try archive(
            revision: 1,
            now: createdAt,
            deleteAfter: createdAt.addingTimeInterval(60)
        )
        _ = try library.install(
            try retained.encoded(
                purpose: .offlineNavigation,
                now: createdAt
            ),
            expectedIdentity: WatchRouteIdentityV1(archive: retained)
        )
        expect(library.routes.count == 1, "unexpired route is selectable")
        currentTime = createdAt.addingTimeInterval(60)
        library.reload()
        let remainingFiles = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "routev1" } ?? []
        expect(
            library.routes.isEmpty && remainingFiles.isEmpty,
            "retention expiry removes the durable route at its boundary"
        )

        let compatible = try archive(revision: 2, now: createdAt)
        let futureArchive = NavigationRouteArchiveV1(
            schemaVersion: NavigationRouteArchiveV1.schemaVersion + 1,
            route: compatible.route,
            createdAt: compatible.createdAt,
            deleteAfter: compatible.deleteAfter,
            contentHash: compatible.contentHash
        )
        expectThrows(
            NavigationRouteArchiveError.invalidSchemaVersion(2),
            "a newer route schema is rejected instead of downgraded"
        ) {
            try futureArchive.validate(
                purpose: .offlineNavigation,
                now: createdAt
            )
        }

        let journalURL = root.appendingPathComponent("future-journal.plist")
        let journalStore = WatchNavigationJournalStore(fileURL: journalURL)
        let identity = WatchRouteIdentityV1(archive: compatible)
        let journal = WatchNavigationJournalV1(
            identity: identity,
            mode: .offline,
            navigationGeneration: 1,
            currentStepIndex: 0,
            lastLocation: nil,
            startedAt: createdAt,
            updatedAt: createdAt
        )
        var plist = try PropertyListSerialization.propertyList(
            from: PropertyListEncoder().encode(journal),
            format: nil
        ) as! [String: Any]
        plist["schema"] = Int(WatchNavigationJournalV1.schemaVersion + 1)
        try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        ).write(to: journalURL)
        expectThrows(
            WatchNavigationJournalError.invalid,
            "a newer navigation journal schema fails closed"
        ) {
            _ = try journalStore.load(now: createdAt)
        }
    }

    private static func testActiveRoutePinAndDeferredDeletion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "watch-offline-route-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "watch-offline-route-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = NavigationRouteFileStoreV1(
            rootDirectory: root,
            limits: .watch
        )
        let library = WatchRouteLibrary(
            store: store,
            now: { now },
            defaults: defaults
        )
        let first = try archive(revision: 1, now: now)
        let firstData = try first.encoded(
            purpose: .offlineNavigation,
            now: now
        )
        _ = try library.install(
            firstData,
            expectedIdentity: WatchRouteIdentityV1(archive: first)
        )
        let identity = WatchRouteIdentityV1(archive: first)
        let renamed = try WatchRouteDisplayNamesEnvelopeV1(
            revision: 1,
            entries: [
                try WatchRouteDisplayNameV1(
                    identity: identity,
                    name: "Shanghai Morning Ride"
                )
            ]
        )
        library.receiveApplicationContext([
            WatchRouteDisplayNamesEnvelopeV1.applicationContextKey:
                try renamed.encoded()
        ])
        expect(
            library.displayName(for: library.routes[0]) ==
                "Shanghai Morning Ride",
            "an exact iPhone route rename is rendered on Watch"
        )
        let restoredLibrary = WatchRouteLibrary(
            store: store,
            now: { now },
            defaults: defaults
        )
        expect(
            restoredLibrary.displayName(for: restoredLibrary.routes[0]) ==
                "Shanghai Morning Ride",
            "the synced route display name survives Watch relaunch"
        )
        _ = try library.activate(identity)

        let replacement = try archive(revision: 2, now: now)
        expectThrows(
            WatchRouteLibraryError.activeRoutePinned,
            "an active route revision is pinned"
        ) {
            _ = try library.install(
                try replacement.encoded(
                    purpose: .offlineNavigation,
                    now: now
                ),
                expectedIdentity: WatchRouteIdentityV1(
                    archive: replacement
                )
            )
        }
        try library.delete(identity)
        expect(
            library.pendingDeletionIdentity == identity,
            "active route deletion becomes a durable tombstone"
        )
        _ = try library.record(matching: identity)
        library.deactivate(identity)
        expect(
            library.activeIdentity == nil &&
                library.pendingDeletionIdentity == nil,
            "deactivation applies the exact deferred deletion"
        )
        expectThrows(
            NavigationRouteFileStoreError.notFound,
            "deferred deletion removes the route only after stop"
        ) {
            _ = try library.record(matching: identity)
        }
    }

    private static func testNavigationJournalRoundTripAndValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "watch-navigation-journal-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("active.plist")
        let store = WatchNavigationJournalStore(fileURL: file)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let identity = WatchRouteIdentityV1(
            routeID: UUID(
                uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            )!,
            revision: 1,
            contentHash: String(repeating: "a", count: 64)
        )
        let sample = NavigationLocationSampleV1(
            coordinate: RouteCoordinateV1(latitude: 1, longitude: 2),
            horizontalAccuracyMeters: 5,
            courseDegrees: 90,
            speedMetersPerSecond: 4,
            altitudeMeters: 8,
            timestamp: now
        )
        let journal = WatchNavigationJournalV1(
            identity: identity,
            mode: .offline,
            navigationGeneration: 7,
            currentStepIndex: 3,
            lastLocation: WatchNavigationJournalLocationV1(sample),
            startedAt: now.addingTimeInterval(-60),
            updatedAt: now
        )
        try store.save(journal)
        try expect(
            try store.load(now: now) == journal,
            "navigation journal atomically round-trips"
        )
        try store.clear()
        try expect(
            try store.load(now: now) == nil,
            "navigation journal clear is exact and idempotent"
        )

        let cached = WatchNavigationJournalV1(
            identity: identity,
            mode: .onlineUsingCachedRoute,
            navigationGeneration: 8,
            currentStepIndex: 3,
            lastLocation: WatchNavigationJournalLocationV1(sample),
            startedAt: now.addingTimeInterval(-60),
            updatedAt: now
        )
        try store.save(cached)
        try expect(
            try store.load(now: now) == cached,
            "an installed route may recover as an online cached route"
        )
        let activeOnlyOnline = WatchNavigationJournalV1(
            identity: identity,
            mode: .online,
            navigationGeneration: 9,
            currentStepIndex: 3,
            lastLocation: WatchNavigationJournalLocationV1(sample),
            startedAt: now.addingTimeInterval(-60),
            updatedAt: now
        )
        expectThrows(
            WatchNavigationJournalError.invalid,
            "active-only online route geometry is never journaled"
        ) {
            _ = try activeOnlyOnline.validated(now: now)
        }

        let future = WatchNavigationJournalV1(
            identity: identity,
            mode: .offline,
            navigationGeneration: 7,
            currentStepIndex: 3,
            lastLocation: nil,
            startedAt: now,
            updatedAt: now.addingTimeInterval(301)
        )
        expectThrows(
            WatchNavigationJournalError.invalid,
            "future recovery journals are rejected"
        ) {
            _ = try future.validated(now: now)
        }
    }

    private static func archive(
        routeID: UUID = UUID(
            uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        )!,
        revision: UInt32,
        now: Date,
        deleteAfter: Date? = nil,
        provider: RouteProviderMetadataV1 = RouteProviderPolicyV1.importedGPX,
        sourceReference: RouteSourceReferenceV1? = nil
    ) throws -> NavigationRouteArchiveV1 {
        let points = [
            RouteCoordinateV1(latitude: 1, longitude: 2),
            RouteCoordinateV1(latitude: 1, longitude: 2.001),
        ]
        let route = NavigationRouteV1(
            id: routeID,
            revision: revision,
            provider: provider,
            sourceReference: sourceReference,
            localeIdentifier: "en_US",
            transportType: .cycling,
            source: RouteEndpointV1(
                coordinate: points[0],
                label: "Start"
            ),
            destination: RouteEndpointV1(
                coordinate: points[1],
                label: "Finish"
            ),
            bounds: RouteBoundsV1.enclosing(points)!,
            distanceMeters: 111,
            expectedTravelTimeSeconds: 60,
            name: "Pinned route",
            points: points,
            steps: [
                NavigationRouteStepV1(
                    id: 1,
                    geometryStartIndex: 0,
                    geometryEndIndex: 1,
                    instruction: "Arrive",
                    maneuver: .arrive,
                    distanceMeters: 111
                ),
            ],
            normalizationVersion: 1
        )
        return try NavigationRouteArchiveV1.create(
            route: route,
            createdAt: now,
            deleteAfter: deleteAfter,
            purpose: .offlineNavigation
        )
    }

    private static func expect(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) rethrows {
        guard try condition() else { fatalError("FAILED: \(message)") }
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
