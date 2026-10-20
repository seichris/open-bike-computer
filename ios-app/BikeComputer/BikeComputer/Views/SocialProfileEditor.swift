import PhotosUI
import SwiftUI

struct SocialProfileEditor: View {
    @ObservedObject var store: SocialCoordinator
    let profile: SocialProfile
    private enum Field { case name, username }
    @FocusState private var focusedField: Field?
    @State private var previousField: Field?
    @State private var name: String
    @State private var username: String
    @State private var submittedName: String
    @State private var submittedUsername: String
    @State private var selected: PhotosPickerItem?
    @State private var savingPhoto = false
    @State private var pendingSaves = 0
    @State private var error: String?

    init(store: SocialCoordinator, profile: SocialProfile) {
        self.store = store
        self.profile = profile
        _name = State(initialValue: profile.displayName)
        _username = State(initialValue: profile.username ?? "")
        _submittedName = State(initialValue: profile.displayName)
        _submittedUsername = State(initialValue: profile.username ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Display name", text: $name)
                    .textContentType(.name)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.next)
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .username)
                    .submitLabel(.done)
                HStack {
                    if store.capabilities.media {
                        PhotosPicker("Choose photo", selection: $selected, matching: .images)
                    }
                    Button("Remove photo", role: .destructive, action: removePhoto)
                        .disabled(store.profile?.avatarID == nil)
                }
                .buttonStyle(.borderless)
                .disabled(savingPhoto)
                if let avatar = store.profile?.avatarID, let image = store.photos[avatar] {
                    HStack {
                        Spacer()
                        SocialProfilePortrait(profile: store.profile, image: image, size: 120)
                        Spacer()
                    }
                }
            } header: {
                Text("Profile")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your name and photo are visible to riders who look up your exact profile, friends, and accepted ride members. Your location stays private until you share it in a ride.")
                    Text(pendingSaves > 0 || savingPhoto ? "Saving…" : "Changes save automatically.")
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
        }
        .navigationTitle("Your profile")
        .onChange(of: focusedField) { next in
            if let previousField { save(previousField) }
            previousField = next
        }
        .onSubmit { focusedField = focusedField == .name ? .username : nil }
        .onDisappear {
            save(.name)
            save(.username)
        }
        .task(id: selected) { await saveSelectedPhoto() }
    }

    private func save(_ field: Field) {
        let value = field == .name
            ? name.trimmingCharacters(in: .whitespacesAndNewlines) : SocialUsername.normalized(username)
        let submitted = field == .name ? submittedName : submittedUsername
        guard value != submitted else { return }
        guard (field == .name && !value.isEmpty && value.count <= 80)
            || (field == .username && value.range(of: "^[a-z][a-z0-9_]{2,29}$", options: .regularExpression) != nil) else {
            error = field == .name ? "Enter a name of 1–80 characters."
                : "Usernames use 3–30 letters, numbers or underscores and start with a letter."
            return
        }
        guard store.profile?.id == profile.id else { return }
        if field == .name { submittedName = value } else { submittedUsername = value }
        let generation = store.session.generation
        pendingSaves += 1
        error = nil
        Task { @MainActor in
            defer { pendingSaves -= 1 }
            do {
                guard store.session.generation == generation, store.profile?.id == profile.id else {
                    throw SocialFailure.accountChanged
                }
                if field == .name { try await store.saveProfileName(value) }
                else { try await store.saveProfileUsername(value) }
            } catch {
                if field == .name, submittedName == value { submittedName = store.profile?.displayName ?? "" }
                if field == .username, submittedUsername == value { submittedUsername = store.profile?.username ?? "" }
                self.error = "Couldn’t save this change. \(error.localizedDescription)"
                if store.session.generation == generation { store.error = self.error }
            }
        }
    }

    private func saveSelectedPhoto() async {
        guard let selected else { return }
        savingPhoto = true
        error = nil
        let generation = store.session.generation
        defer { savingPhoto = false }
        do {
            guard let data = try await selected.loadTransferable(type: Data.self) else { throw SocialFailure.invalidResponse }
            try Task.checkCancellation()
            guard store.session.generation == generation, store.profile?.id == profile.id else { throw SocialFailure.accountChanged }
            try await store.setPhoto(data)
        } catch is CancellationError {
        } catch { self.error = "Couldn’t save this photo. \(error.localizedDescription)" }
    }

    private func removePhoto() {
        guard store.profile?.id == profile.id else { return }
        savingPhoto = true
        error = nil
        let generation = store.session.generation
        Task { @MainActor in
            defer { savingPhoto = false }
            do {
                guard store.session.generation == generation, store.profile?.id == profile.id else {
                    throw SocialFailure.accountChanged
                }
                try await store.removePhoto()
            }
            catch { self.error = "Couldn’t remove this photo. \(error.localizedDescription)" }
        }
    }
}
