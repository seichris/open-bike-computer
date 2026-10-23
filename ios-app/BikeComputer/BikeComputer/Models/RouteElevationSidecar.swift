import Foundation

/// Exact saved-route archive a sidecar belongs to. A sidecar for a deleted,
/// replaced or expired archive is never used and is pruned on reload.
nonisolated struct RouteElevationArchiveBindingV1: Codable, Equatable, Hashable, Sendable {
    let routeID: UUID
    let revision: UInt32
    let contentHash: String
}

/// Phone-only companion of a durable saved route. It keeps validated GPX
/// `<ele>` values (decimetres) and the last service profile so a saved route's
/// elevation works offline. It holds no coordinates; Apple Maps routes never
/// receive one because their geometry is not sent to the elevation service.
nonisolated struct RouteElevationSidecarV1: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumBytes = 2 * 1_024 * 1_024

    let schemaVersion: Int
    let binding: RouteElevationArchiveBindingV1
    let geometryDigest: String
    let gpxVertexElevationsDecimeters: [Int32?]?
    let serviceProfile: RouteElevationProfileV1?

    init(
        binding: RouteElevationArchiveBindingV1,
        geometryDigest: String,
        gpxVertexElevations: [Double?]?,
        serviceProfile: RouteElevationProfileV1?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.binding = binding
        self.geometryDigest = geometryDigest
        gpxVertexElevationsDecimeters = gpxVertexElevations?.map { value in
            guard let value, value.isFinite, abs(value) <= 100_000 else { return nil }
            return Int32((value * 10).rounded(.toNearestOrAwayFromZero))
        }
        self.serviceProfile = serviceProfile
    }

    var gpxVertexElevations: [Double?]? {
        gpxVertexElevationsDecimeters?.map { $0.map { Double($0) / 10 } }
    }

    func replacingServiceProfile(_ profile: RouteElevationProfileV1?) -> Self {
        Self(binding: binding, geometryDigest: geometryDigest,
             gpxVertexElevations: gpxVertexElevations, serviceProfile: profile)
    }
}

nonisolated final class RouteElevationSidecarStoreV1 {
    let directory: URL
    private let fileManager: FileManager

    init(directory: URL, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    private func fileURL(routeID: UUID) -> URL {
        directory.appendingPathComponent(routeID.uuidString.lowercased() + ".json")
    }

    func load(_ binding: RouteElevationArchiveBindingV1) -> RouteElevationSidecarV1? {
        let url = fileURL(routeID: binding.routeID)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= RouteElevationSidecarV1.maximumBytes,
              let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(RouteElevationSidecarV1.self, from: data),
              sidecar.schemaVersion == RouteElevationSidecarV1.currentSchemaVersion,
              sidecar.binding == binding else {
            return nil
        }
        return sidecar
    }

    func save(_ sidecar: RouteElevationSidecarV1) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sidecar)
        guard data.count <= RouteElevationSidecarV1.maximumBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(directoryValues)
        let destination = fileURL(routeID: sidecar.binding.routeID)
        try data.write(to: destination, options: .atomic)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDestination = destination
        try? mutableDestination.setResourceValues(values)
#if os(iOS) || os(watchOS)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
#endif
    }

    func remove(routeID: UUID) {
        try? fileManager.removeItem(at: fileURL(routeID: routeID))
    }

    /// Removes sidecars whose archive is gone, replaced or expired.
    func prune(keeping bindings: Set<RouteElevationArchiveBindingV1>) {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let keep = Dictionary(bindings.map { ($0.routeID.uuidString.lowercased() + ".json", $0) },
                              uniquingKeysWith: { first, _ in first })
        for file in files where file.pathExtension == "json" {
            guard let binding = keep[file.lastPathComponent], load(binding) != nil else {
                try? fileManager.removeItem(at: file)
                continue
            }
        }
    }
}
