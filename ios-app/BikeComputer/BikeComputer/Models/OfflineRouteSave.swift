import Foundation

/// A staged save is memory-only. Drafts come from the GPX importer, a selected
/// canonical MapKit route, or an exact library read. Never serialize MKRoute.
struct OfflineRouteSaveDraft: Identifiable, Equatable {
    var id: UUID { archive.routeID }
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

    /// Takes the already-validated canonical route selected in the planner,
    /// preserving its UUID, ordered geometry, instructions and normalization.
    /// This never converts Apple geometry to a user-GPX provider.
    static func plannedMapKit(_ route: NavigationRouteV1, createdAt: Date) throws -> Self {
        guard route.provider == RouteProviderPolicyV1.mapKit else {
            throw OfflineRouteSaveError.sourceNotApproved
        }
        try route.validate()
        let suggestedName = route.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = suggestedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? "\(route.source.label) → \(route.destination.label)"
        let saved = NavigationRouteV1(
            id: route.id, revision: route.revision,
            provider: RouteProviderPolicyV1.mapKitSavedOnPhone,
            sourceReference: route.sourceReference,
            localeIdentifier: route.localeIdentifier, transportType: route.transportType,
            source: route.source, destination: route.destination, bounds: route.bounds,
            distanceMeters: route.distanceMeters,
            expectedTravelTimeSeconds: route.expectedTravelTimeSeconds,
            name: name, points: route.points, steps: route.steps,
            normalizationVersion: route.normalizationVersion
        )
        return Self(archive: try NavigationRouteArchiveV1.create(
            route: saved, createdAt: createdAt, purpose: .offlineNavigation
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
    /// revision, or renews a provider lease. This is for a new GPX/MapKit draft.
    func namedArchive(_ proposedName: String) throws -> NavigationRouteArchiveV1 {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 512 else {
            throw OfflineRouteSaveError.invalidName
        }
        guard !requiresExistingArchive,
              [RouteProviderPolicyV1.importedGPX, RouteProviderPolicyV1.mapKitSavedOnPhone]
                .contains(archive.route.provider) else {
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
        lhs.provider == RouteProviderPolicyV1.importedGPX && sameSavableContent(lhs, rhs)
    }

    static func sameSavableContent(_ lhs: NavigationRouteV1, _ rhs: NavigationRouteV1) -> Bool {
        [RouteProviderPolicyV1.importedGPX, RouteProviderPolicyV1.mapKitSavedOnPhone]
            .contains(lhs.provider) && lhs.provider == rhs.provider &&
            lhs.localeIdentifier == rhs.localeIdentifier &&
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
        case .sourceNotApproved: "This route cannot be saved offline. Select a valid planned or saved route, or import a GPX file."
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
        guard result == nil else { return }
        guard let draft else {
            errorMessage = OfflineRouteSaveError.noSelection.localizedDescription
            return
        }
        guard draft.isEligible(now: now) else {
            errorMessage = OfflineRouteSaveError.sourceNotApproved.localizedDescription
            return
        }
        guard canSave(now: now) else {
            errorMessage = OfflineRouteSaveError.invalidName.localizedDescription
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
