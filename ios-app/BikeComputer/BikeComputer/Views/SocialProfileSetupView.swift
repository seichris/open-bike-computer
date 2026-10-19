import PhotosUI
import SwiftUI

struct SocialProfileSetupPresentation: ViewModifier {
    @ObservedObject var store: SocialCoordinator
    var enabled = true
    @State private var presentedProfile: SocialProfile?
    @State private var generation = UUID()

    func body(content: Content) -> some View {
        content
            .task(id: store.profile) { offerSetup() }
            .sheet(item: $presentedProfile) { profile in
                NavigationStack {
                    SocialProfileSetupView(store: store, profile: profile, generation: generation)
                }
            }
    }

    private func offerSetup() {
        guard enabled, store.session.state == .signedIn, let profile = store.profile else {
            presentedProfile = nil
            return
        }
        let history = SocialProfileSetupHistory(defaults: .standard)
        guard presentedProfile == nil, history.shouldOffer(for: profile) else { return }
        generation = store.session.generation
        presentedProfile = profile
        history.recordOffer(for: profile)
    }
}

struct SocialProfileSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SocialCoordinator
    let profile: SocialProfile
    let generation: UUID
    @State private var draft: SocialProfileDraft
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var photo: Data?
    @State private var isSaving = false
    @State private var isLoadingPhoto = false
    @State private var error: String?
    @State private var didSaveName = false

    init(store: SocialCoordinator, profile: SocialProfile, generation: UUID) {
        self.store = store
        self.profile = profile
        self.generation = generation
        _draft = State(initialValue: SocialProfileDraft(profile: profile))
    }

    var body: some View {
        Form {
            Section {
                Text("Choose how other riders see you. You can change these details later.")
                TextField("Name", text: $draft.name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("profileSetup.name")
                TextField("Username", text: $draft.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("profileSetup.username")
            } footer: {
                Text("Usernames use 3–30 letters, numbers or underscores and start with a letter. Your name and username are visible to other riders.")
            }

            if store.capabilities.media {
                Section {
                    SocialProfilePhotoPicker(
                        profile: profile,
                        image: photo.flatMap { UIImage(data: $0) }
                            ?? store.profile?.avatarID.flatMap { store.photos[$0] },
                        selection: $selectedPhoto,
                        isLoading: isLoadingPhoto
                    )
                } footer: {
                    Text("A photo is optional. Your initials appear until you add one.")
                }
            }

            Section {
                Button(isSaving ? "Saving…" : "Save profile", action: save)
                    .disabled(!draft.isValid || isSaving || isLoadingPhoto)
                    .accessibilityIdentifier("profileSetup.save")
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Complete your profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Not now") { dismiss() }.disabled(isSaving)
            }
        }
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .task(id: selectedPhoto) { await loadPhoto() }
        .onChange(of: store.session.generation) { value in
            if value != generation { dismiss() }
        }
    }

    private func loadPhoto() async {
        guard let selection = selectedPhoto else { return }
        isLoadingPhoto = true
        defer { if selectedPhoto == selection { isLoadingPhoto = false } }
        do {
            guard let data = try await selection.loadTransferable(type: Data.self),
                  UIImage(data: data) != nil else { throw SocialFailure.invalidResponse }
            try Task.checkCancellation()
            guard selectedPhoto == selection else { return }
            photo = data
            error = nil
        } catch is CancellationError {
            // A newer selection owns the preview.
        } catch {
            guard selectedPhoto == selection else { return }
            self.error = "This photo couldn’t be loaded. Choose another photo or continue without one."
        }
    }

    private func save() {
        isSaving = true
        error = nil
        didSaveName = false
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try checkAccount()
                try await store.saveProfile(username: draft.normalizedUsername,
                    name: draft.normalizedName, privacy: store.profile?.privacy ?? SocialPrivacy())
                didSaveName = true
                try checkAccount()
                if let photo { try await store.setPhoto(photo) }
                try checkAccount()
                dismiss()
            } catch {
                self.error = didSaveName
                    ? "Your name and username were saved. The photo wasn’t saved. Try again or choose Not now."
                    : error.localizedDescription
            }
        }
    }

    private func checkAccount() throws {
        guard store.session.generation == generation, store.profile?.id == profile.id else {
            throw SocialFailure.accountChanged
        }
    }
}

private struct SocialProfilePhotoPicker: View {
    let profile: SocialProfile
    let image: UIImage?
    @Binding var selection: PhotosPickerItem?
    let isLoading: Bool

    var body: some View {
        VStack(spacing: 12) {
            SocialProfilePortrait(profile: profile, image: image)
            PhotosPicker(selection: $selection, matching: .images) {
                Label("Choose photo", systemImage: "photo")
            }
            if isLoading { ProgressView("Loading photo…") }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
