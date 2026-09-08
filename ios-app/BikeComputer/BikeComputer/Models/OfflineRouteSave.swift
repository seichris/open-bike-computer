import Foundation

/// A staged import is memory-only. Only the GPX importer or an exact library
/// read can construct a draft; MapKit alternatives have no conversion here.
struct OfflineRouteSaveDraft {
    let archive: NavigationRouteArchiveV1
    let requiresExistingArchive: Bool

    private init(archive: NavigationRouteArchiveV1, requiresExistingArchive: Bool) {
        self.archive = archive
        self.requiresExistingArchive = requiresExistingArchive
    }

    static func gpx(data: Data, fileName: String, now: Date) throws -> Self {
        Self(archive: try GPXRouteImporterV1.archive(
            data: data, fallbackName: fileName, createdAt: now
        ), requiresExistingArchive: false)
    }

    static func installed(_ archive: NavigationRouteArchiveV1, now: Date) throws -> Self {
        try archive.validate(purpose: .offlineNavigation, now: now)
        return Self(archive: archive, requiresExistingArchive: true)
    }

    func isEligible(now: Date) -> Bool {
        (try? archive.validate(purpose: .offlineNavigation, now: now)) != nil
    }

    /// Local naming never relabels the provider, changes geometry, increments a
    /// revision, or renews a provider lease. This is for a NEW GPX import only.
    func namedArchive(_ proposedName: String) throws -> NavigationRouteArchiveV1 {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else {
            throw OfflineRouteSaveError.invalidName
        }
        guard !requiresExistingArchive,
              archive.route.provider == RouteProviderPolicyV1.importedGPX else {
            throw OfflineRouteSaveError.sourceNotApproved
        }
        let route = archive.route
        return try NavigationRouteArchiveV1.create(
            route: NavigationRouteV1(
                id: route.id, revision: route.revision, provider: route.provider,
                sourceReference: route.sourceReference,
                localeIdentifier: route.localeIdentifier, transportType: route.transportType,
                source: route.source, destination: route.destination, bounds: route.bounds,
                distanceMeters: route.distanceMeters,
                expectedTravelTimeSeconds: route.expectedTravelTimeSeconds,
                name: trimmed, points: route.points, steps: route.steps,
                normalizationVersion: route.normalizationVersion
            ),
            createdAt: archive.createdAt, deleteAfter: archive.deleteAfter,
            purpose: .offlineNavigation
        )
    }

    /// Exact semantic duplicate, not proximity or an endpoint-only match. Ignore
    /// the import UUID, timestamp and editable name; preserve ordered geometry,
    /// navigation instructions, normalization and provenance. Never cross sources.
    static func sameGPXContent(_ lhs: NavigationRouteV1, _ rhs: NavigationRouteV1) -> Bool {
        lhs.provider == RouteProviderPolicyV1.importedGPX && lhs.provider == rhs.provider &&
            lhs.sourceReference == rhs.sourceReference &&
            lhs.normalizationVersion == rhs.normalizationVersion &&
            lhs.transportType == rhs.transportType && lhs.source == rhs.source &&
            lhs.destination == rhs.destination && lhs.points == rhs.points &&
            lhs.steps == rhs.steps && lhs.distanceMeters == rhs.distanceMeters &&
            lhs.expectedTravelTimeSeconds == rhs.expectedTravelTimeSeconds
    }
}

struct OfflineRouteSaveResult: Equatable {
    let summary: PlannedRouteSummaryV1
    let alreadySaved: Bool

    var message: String {
        alreadySaved ? "Already saved on this iPhone. The existing route was kept." :
            "Saved on this iPhone. You can start this route without an internet connection."
    }
}

nonisolated enum OfflineRouteSaveError: LocalizedError {
    case invalidName
    case sourceNotApproved
    case noSelection
    case storageFailure

    var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a route name of at most 512 UTF-8 bytes."
        case .sourceNotApproved: "This source is not approved for offline route storage. Import a user-owned GPX or select a valid saved route."
        case .noSelection: "Select or import a route first."
        case .storageFailure: "The route could not be saved. Check available iPhone storage and try again."
        }
    }
}

/// Synchronous commit boundary: cancellation before Save has no disk effects;
/// success is published only after the library's verified atomic write/read.
/// A failed save keeps its draft and identity for an explicit retry.
struct OfflineRouteSaveInteraction {
    private(set) var draft: OfflineRouteSaveDraft?
    var proposedName = ""
    private(set) var result: OfflineRouteSaveResult?
    private(set) var errorMessage: String?

    mutating func select(_ draft: OfflineRouteSaveDraft, displayName: String? = nil) {
        self.draft = draft
        proposedName = displayName ?? draft.archive.route.name ?? draft.archive.route.destination.label
        result = nil
        errorMessage = nil
    }

    func canSave(now: Date) -> Bool {
        guard result == nil, let draft, draft.isEligible(now: now) else { return false }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return draft.requiresExistingArchive || (!name.isEmpty && name.utf8.count <= 512)
    }

    mutating func save(
        now: Date,
        commit: (OfflineRouteSaveDraft, String) throws -> OfflineRouteSaveResult
    ) {
        guard canSave(now: now), let draft else {
            errorMessage = OfflineRouteSaveError.sourceNotApproved.localizedDescription
            return
        }
        do {
            result = try commit(draft, proposedName)
            errorMessage = nil
        } catch {
            result = nil
            errorMessage = (error as? LocalizedError)?.errorDescription ??
                OfflineRouteSaveError.storageFailure.localizedDescription
        }
    }

    mutating func cancel() { self = Self() }
}
