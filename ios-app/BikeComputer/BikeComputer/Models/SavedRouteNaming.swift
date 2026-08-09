import Foundation

nonisolated struct SavedRouteRenameCommit: Equatable {
    let routeID: UUID
    let proposedName: String
}

nonisolated struct SavedRouteRenameInteraction: Equatable {
    private(set) var editingRouteID: UUID?
    private(set) var draftName = ""

    mutating func begin(
        routeID: UUID,
        currentName: String
    ) -> SavedRouteRenameCommit? {
        let previous = finish()
        editingRouteID = routeID
        draftName = currentName
        return previous
    }

    mutating func updateDraft(_ value: String) {
        draftName = value
    }

    mutating func finishIfFocusMoved(
        to focusedRouteID: UUID?
    ) -> SavedRouteRenameCommit? {
        guard focusedRouteID != editingRouteID else { return nil }
        return finish()
    }

    mutating func finish() -> SavedRouteRenameCommit? {
        guard let editingRouteID else { return nil }
        let commit = SavedRouteRenameCommit(
            routeID: editingRouteID,
            proposedName: draftName
        )
        self.editingRouteID = nil
        draftName = ""
        return commit
    }
}

nonisolated struct SavedRouteDisplayNames: Equatable {
    static let defaultsKey = "savedRouteDisplayNames.v1"

    private(set) var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values.compactMapValues { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    init(defaults: UserDefaults) {
        self.init(values: defaults.dictionary(forKey: Self.defaultsKey)?
            .compactMapValues { $0 as? String } ?? [:])
    }

    func displayName(routeID: UUID, defaultName: String) -> String {
        values[Self.key(routeID)] ?? defaultName
    }

    @discardableResult
    mutating func rename(
        routeID: UUID,
        defaultName: String,
        to proposedName: String
    ) -> String {
        let currentName = displayName(
            routeID: routeID,
            defaultName: defaultName
        )
        let trimmed = proposedName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return currentName }
        values[Self.key(routeID)] = trimmed
        return trimmed
    }

    @discardableResult
    mutating func remove(routeID: UUID) -> Bool {
        values.removeValue(forKey: Self.key(routeID)) != nil
    }

    func persist(to defaults: UserDefaults) {
        defaults.set(values, forKey: Self.defaultsKey)
    }

    private static func key(_ routeID: UUID) -> String {
        routeID.uuidString.lowercased()
    }
}
