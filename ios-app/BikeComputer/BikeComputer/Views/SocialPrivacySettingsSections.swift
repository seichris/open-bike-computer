import SwiftUI

struct SocialPrivacySettingsSections: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @ObservedObject var store: SocialCoordinator
    let profile: SocialProfile
    @State private var privacy: SocialPrivacy
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var radius = "500"
    @State private var isSaving = false
    @State private var error: String?

    init(store: SocialCoordinator, profile: SocialProfile) {
        self.store = store
        self.profile = profile
        _privacy = State(initialValue: profile.privacy ?? SocialPrivacy())
    }

    var body: some View {
        Group {
            Section {
                Toggle("Allow friend requests", isOn: binding(.requests))
                Toggle("Allow ride invitations from friends", isOn: binding(.invitations))
                Toggle("Request and invitation alerts", isOn: binding(.notifications))
                Toggle("Friend request notifications", isOn: binding(.friendNotifications))
                    .disabled(!privacy.notifications || !store.alertsAuthorized)
                Toggle("Ride invitation notifications", isOn: binding(.rideNotifications))
                    .disabled(!privacy.notifications || !store.alertsAuthorized)
            } header: {
                Text("Privacy and notifications")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shared routes start as Only me. Sharing a route never shares your live location.")
                    Text(isSaving ? "Saving…" : "Changes save automatically.")
                    if profile.needsProfileSetup { Text("Complete your profile to change account preferences.") }
                    if store.alertsDenied {
                        Button("Allow notifications in iPhone Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                    if case .unavailable(let reason) = store.notificationStatus { Text(reason) }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }

            Section {
                ForEach(Array(privacy.zones.enumerated()), id: \.offset) { index, zone in
                    HStack {
                        Text("Private area \(index + 1) · \(Int(zone.radius)) m")
                        Spacer()
                        Button("Remove", role: .destructive) { removeArea(at: index) }
                            .buttonStyle(.borderless)
                    }
                }
                TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
                TextField("Radius in metres (200–20000)", text: $radius).keyboardType(.numberPad)
                Button("Add private area", action: addArea)
                    .disabled(privacy.zones.count >= 10)
            } header: {
                Text("Private areas")
            } footer: {
                Text("Changing private areas hides previously published rides until you share them again. Start and finish areas are trimmed automatically.")
            }
        }
        .disabled(isSaving || profile.needsProfileSetup)
        .task { await store.refreshNotificationAuthorization() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await store.refreshNotificationAuthorization() } }
        }
        .onChange(of: store.profile?.privacy) { value in
            if !isSaving, let value { privacy = value }
        }
    }

    private func binding(_ flag: SocialPrivacyFlag) -> Binding<Bool> {
        Binding(
            get: { privacy[keyPath: flag.keyPath] && (flag != .notifications || store.alertsAuthorized) },
            set: { value in save(flag, value: value) }
        )
    }

    private func save(_ flag: SocialPrivacyFlag, value: Bool) {
        guard !isSaving, store.profile?.id == profile.id else { return }
        privacy[keyPath: flag.keyPath] = value
        persist { generation in
            if flag == .notifications && value {
                guard try await store.enableNotifications() else {
                    throw SocialFailure.server("allow_notifications_in_iPhone_Settings")
                }
            }
            guard store.session.generation == generation, store.profile?.id == profile.id else { throw SocialFailure.accountChanged }
            try await store.savePrivacy(flag, value: value)
        }
    }

    private func addArea() {
        guard let lat = Double(latitude), let lon = Double(longitude), let metres = Double(radius),
              (-90...90).contains(lat), (-180...180).contains(lon), (200...20000).contains(metres) else {
            error = "Enter valid coordinates and a radius between 200 and 20000 metres."
            return
        }
        var zones = privacy.zones
        zones.append(SocialZone(latitude: lat, longitude: lon, radius: metres))
        saveAreas(zones, clearsDraft: true)
    }

    private func removeArea(at index: Int) {
        guard !isSaving, privacy.zones.indices.contains(index) else { return }
        var zones = privacy.zones
        zones.remove(at: index)
        saveAreas(zones, clearsDraft: false)
    }

    private func saveAreas(_ zones: [SocialZone], clearsDraft: Bool) {
        guard !isSaving, store.profile?.id == profile.id else { return }
        privacy.zones = zones
        persist { generation in
            guard store.session.generation == generation, store.profile?.id == profile.id else { throw SocialFailure.accountChanged }
            try await store.savePrivateAreas(zones)
            if clearsDraft { latitude = ""; longitude = "" }
        }
    }

    private func persist(_ operation: @escaping @MainActor (UUID) async throws -> Void) {
        isSaving = true
        error = nil
        let generation = store.session.generation
        Task { @MainActor in
            defer {
                if store.profile?.id == profile.id { privacy = store.profile?.privacy ?? SocialPrivacy() }
                isSaving = false
            }
            do {
                guard store.session.generation == generation else { throw SocialFailure.accountChanged }
                try await operation(generation)
            }
            catch { self.error = "Couldn’t save this change. \(error.localizedDescription)" }
        }
    }
}
