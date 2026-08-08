import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct WatchNavigationJournalV1: Codable, Equatable {
    static let schemaVersion: UInt16 = 1

    let schema: UInt16
    let identity: WatchRouteIdentityV1
    let mode: NavigationModeV1
    let navigationGeneration: UInt32
    let currentStepIndex: Int
    let lastLocation: WatchNavigationJournalLocationV1?
    let startedAt: Date
    let updatedAt: Date

    init(
        identity: WatchRouteIdentityV1,
        mode: NavigationModeV1,
        navigationGeneration: UInt32,
        currentStepIndex: Int,
        lastLocation: WatchNavigationJournalLocationV1?,
        startedAt: Date,
        updatedAt: Date
    ) {
        schema = Self.schemaVersion
        self.identity = identity
        self.mode = mode
        self.navigationGeneration = navigationGeneration
        self.currentStepIndex = currentStepIndex
        self.lastLocation = lastLocation
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    func validated(now: Date = Date()) throws -> Self {
        guard schema == Self.schemaVersion,
              identity.revision > 0,
              identity.contentHash.count == 64,
              identity.contentHash.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              mode != .online,
              currentStepIndex >= 0,
              startedAt.timeIntervalSince1970.isFinite,
              updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= startedAt,
              updatedAt <= now.addingTimeInterval(300),
              lastLocation?.isValid ?? true else {
            throw WatchNavigationJournalError.invalid
        }
        return self
    }
}

struct WatchNavigationJournalLocationV1: Codable, Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Double
    let courseDegrees: Double
    let speedMetersPerSecond: Double
    let altitudeMeters: Double
    let timestamp: Date

    init(_ sample: NavigationLocationSampleV1) {
        latitude = sample.coordinate.latitude
        longitude = sample.coordinate.longitude
        horizontalAccuracyMeters = sample.horizontalAccuracyMeters
        courseDegrees = sample.courseDegrees
        speedMetersPerSecond = sample.speedMetersPerSecond
        altitudeMeters = sample.altitudeMeters
        timestamp = sample.timestamp
    }

    var isValid: Bool {
        RouteCoordinateV1(latitude: latitude, longitude: longitude).isValid &&
            horizontalAccuracyMeters.isFinite &&
            courseDegrees.isFinite && speedMetersPerSecond.isFinite &&
            altitudeMeters.isFinite &&
            timestamp.timeIntervalSince1970.isFinite
    }

    var sample: NavigationLocationSampleV1 {
        NavigationLocationSampleV1(
            coordinate: RouteCoordinateV1(
                latitude: latitude,
                longitude: longitude
            ),
            horizontalAccuracyMeters: horizontalAccuracyMeters,
            courseDegrees: courseDegrees,
            speedMetersPerSecond: speedMetersPerSecond,
            altitudeMeters: altitudeMeters,
            timestamp: timestamp
        )
    }
}

enum WatchNavigationJournalError: Error, Equatable {
    case invalid
    case unavailable
}

final class WatchNavigationJournalStore {
    private let fileURL: URL
    private let fileManager: FileManager

    convenience init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        self.init(fileURL: base.appendingPathComponent(
            "WatchNavigation/active-navigation-v1.plist",
            isDirectory: false
        ))
    }

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    func load(now: Date = Date()) throws -> WatchNavigationJournalV1? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try PropertyListDecoder()
                .decode(WatchNavigationJournalV1.self, from: data)
                .validated(now: now)
        } catch {
            throw WatchNavigationJournalError.invalid
        }
    }

    func save(_ journal: WatchNavigationJournalV1) throws {
        _ = try journal.validated(now: journal.updatedAt)
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".navigation-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let data = try PropertyListEncoder().encode(journal)
            try data.write(to: temporary)
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
#if os(watchOS)
            try fileManager.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType
                            .completeUntilFirstUserAuthentication,
                ],
                ofItemAtPath: temporary.path
            )
#endif
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(
                    fileURL,
                    withItemAt: temporary
                )
            } else {
                try fileManager.moveItem(at: temporary, to: fileURL)
            }
            try synchronize(directory)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw WatchNavigationJournalError.unavailable
        }
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
            try synchronize(fileURL.deletingLastPathComponent())
        } catch {
            throw WatchNavigationJournalError.unavailable
        }
    }

    private func synchronize(_ directory: URL) throws {
#if canImport(Darwin)
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw WatchNavigationJournalError.unavailable
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw WatchNavigationJournalError.unavailable
        }
#endif
    }
}
