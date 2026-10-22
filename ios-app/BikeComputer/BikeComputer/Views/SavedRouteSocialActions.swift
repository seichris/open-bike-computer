import SwiftUI

struct SavedRouteSocialActions: View {
    @ObservedObject var store: SocialCoordinator
    @ObservedObject var library: PhoneRouteLibrary
    let identity: WatchRouteIdentityV1
    let openProfile: () -> Void
    let groupCreated: () -> Void
    @State private var visibility = "private"
    @State private var shareURL: URL?
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    @State private var unavailable: String?

    private var route: PlannedRouteSummaryV1? {
        library.routes.first { $0.id == identity.routeID && $0.revision == identity.revision && $0.contentHash == identity.contentHash }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if store.session.state != .signedIn { openProfile() }
                else { startGroup() }
            } label: {
                SavedRouteActionLabel(title: "Start Group Ride", icon: "person.2.fill")
            }
            .buttonStyle(.plain)
            .disabled(busy || !loaded || (store.session.state == .signedIn && unavailable != nil))
            .accessibilityIdentifier("startSavedRouteGroupRide")

            Text("Starting a group ride shares this saved route and your live location, speed, distance and times with riders who join. You can stop live sharing at any time.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("Share with")
                Picker("Share with", selection: Binding(get: { visibility }, set: saveVisibility)) {
                    Text("Friends").tag("friends")
                    Text("Only Me").tag("private")
                    Text("Anyone with the link").tag("link")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(busy || !loaded || unavailable != nil)
            }
            .font(.subheadline)
            if visibility == "link" {
                if let shareURL { ShareLink("Share route link", item: shareURL) }
                else {
                    Button("Create route link") { saveVisibility("link") }
                        .disabled(busy || !loaded || unavailable != nil)
                }
            }
            if busy { ProgressView("Saving…").font(.caption) }
            if let unavailable { Text(unavailable).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if !loaded, !busy, error != nil {
                Button("Retry") { Task { await load() } }
            }
        }
        .task(id: "\(store.session.generation)|\(store.session.state)|\(identity.contentHash)") { await load() }
        .onChange(of: store.capabilities) { _ in refreshAvailability() }
        .onChange(of: library.routes) { _ in refreshAvailability() }
    }

    private func refreshAvailability() {
        guard let route else {
            unavailable = "This saved route has changed. Open it again from Saved Routes."
            return
        }
        unavailable = store.sharingUnavailableReason(for: route, in: library)
    }

    private func load() async {
        loaded = false
        visibility = "private"
        shareURL = nil
        error = nil
        refreshAvailability()
        guard store.session.state == .signedIn else { loaded = true; return }
        let generation = store.session.generation
        do {
            if store.profile == nil { try await store.refresh() }
            guard store.session.generation == generation else { return }
            refreshAvailability()
            if let owner = store.profile?.id, unavailable == nil,
               let existing = try await store.savedRouteSharing.load(owner: owner, hash: identity.contentHash, generation: generation) {
                guard store.session.generation == generation else { return }
                visibility = existing.visibility
            }
        } catch {
            guard store.session.generation == generation else { return }
            self.error = "Couldn’t load route sharing. \(error.localizedDescription)"
            return
        }
        loaded = true
    }

    private func saveVisibility(_ value: String) {
        let previous = visibility
        visibility = value
        shareURL = nil
        let generation = store.session.generation
        perform { route in
            let content: SocialContent
            do {
                content = try await store.shareSavedRoute(route, from: library, visibility: value)
            } catch {
                if store.session.generation == generation { visibility = previous }
                throw error
            }
            guard store.session.generation == generation else { throw SocialFailure.accountChanged }
            if value == "link" {
                let response = try await store.client.json("share-links", method: "POST", body: ["contentID": content.id])
                guard store.session.generation == generation else { throw SocialFailure.accountChanged }
                guard let raw = response["url"] as? String, let url = URL(string: raw) else { throw SocialFailure.invalidResponse }
                shareURL = url
            }
        }
    }

    private func startGroup() {
        let generation = store.session.generation
        perform { route in
            let content = try await store.shareSavedRoute(route, from: library, visibility: visibility)
            guard store.session.generation == generation else { throw SocialFailure.accountChanged }
            try await store.createRide(route: content, title: library.displayName(for: route))
            guard store.session.generation == generation else { throw SocialFailure.accountChanged }
            groupCreated()
        }
    }

    private func perform(_ operation: @escaping @MainActor (PlannedRouteSummaryV1) async throws -> Void) {
        guard !busy, let route, unavailable == nil else { return }
        busy = true
        error = nil
        let generation = store.session.generation
        Task { @MainActor in
            defer { busy = false }
            do {
                guard store.session.generation == generation else { throw SocialFailure.accountChanged }
                try await operation(route)
            } catch {
                guard store.session.generation == generation else { return }
                self.error = "Couldn’t complete this change. \(error.localizedDescription)"
            }
        }
    }
}
