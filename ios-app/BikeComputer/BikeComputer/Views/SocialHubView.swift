import PhotosUI
import SwiftUI
import MapKit

struct SocialHubView: View {
    @ObservedObject var store: SocialCoordinator
    @ObservedObject var routeLibrary: PhoneRouteLibrary
    var offersProfileSetup = true
    @State private var username = ""
    @State private var found: SocialProfile?
    @State private var joinCode = ""
    @State private var busy = false
    @State private var deleting = false
    @State private var showsQRCode = false
    @State private var sharingError: String?

    var body: some View {
        List {
            if store.session.state == .unavailable {
                Section { Text("Social riding is not available in this build. Navigation and private workouts are still available.") }
            } else if store.session.state == .restoring {
                Section { ProgressView("Restoring your account…") }
            } else if store.session.state != .signedIn {
                Section {
                    Text("Use the same Apple or Google account as bicino.com.")
                    Button("Continue with Apple") { perform { _ = try await store.session.signInWithApple() } }
                    Button("Continue with Google") { perform { try await store.session.signInWithGoogle() } }
                } header: {
                    Text("Your Bicino account")
                } footer: {
                    Text("Sign-in is optional. Navigation and private rides work without an account.")
                }
            } else {
                if let profile = store.profile {
                    Section {
                        NavigationLink {
                            if profile.needsProfileSetup {
                                SocialProfileSetupView(store: store, profile: profile,
                                    generation: store.session.generation)
                            } else {
                                SocialProfileEditor(store: store, profile: profile)
                            }
                        } label: {
                            HStack {
                                SocialAvatar(profile: profile, image: profile.avatarID.flatMap { store.photos[$0] })
                                VStack(alignment: .leading) {
                                    Text(profile.displayName)
                                    Text(profile.username.map { "@\($0)" } ?? "Complete your profile").font(.caption)
                                }
                            }
                        }
                        SocialProfileActionsRow(
                            profileURL: URL(string: "https://bicino.com/social/profile/\(profile.id)")!,
                            showQRCode: { showsQRCode = true }
                        )
                    }
                }
                if store.live.ride != nil {
                    Section("Group Ride") { SocialLiveControls(store: store, routeLibrary: routeLibrary) }
                }
                if store.live.ride == nil && !store.rides.isEmpty {
                    Section("My Group Rides") {
                        ForEach(store.rides.filter { $0.id != store.live.ride?.id }) { ride in
                            Button(ride.title) { perform { try await store.live.select(ride, shareOnJoin: true) } }
                        }
                    }
                }
                Section {
                    ForEach(store.friends) { friend in
                        HStack {
                            NavigationLink {
                                SocialFriendView(store: store, friend: friend, routeLibrary: routeLibrary)
                            } label: {
                                HStack {
                                    SocialAvatar(profile: friend, image: friend.avatarID.flatMap { store.photos[$0] })
                                    VStack(alignment: .leading) {
                                        Text(friend.displayName)
                                        if let username = friend.username, !username.isEmpty {
                                            Text("@\(username)").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            Toggle("Share live data with \(friend.displayName)", isOn: Binding(
                                get: { store.friendLive.sharingIDs.contains(friend.id) },
                                set: { enabled in setFriendSharing(enabled, with: friend.id) }
                            ))
                            .labelsHidden()
                            .disabled(!store.capabilities.friendSharing || store.friendLive.busyIDs.contains(friend.id))
                        }
                    }
                    SocialRiderSearchRow(username: $username, search: searchForRider)
                    if let found {
                        Text(found.displayName)
                        Button("Send friend request") { perform { try await store.mutate("friend-requests", body: ["profileID": found.id]); self.found = nil } }
                    }
                } header: {
                    Text("Friends")
                } footer: {
                    Text(store.capabilities.friendSharing
                         ? "Each toggle shares your live location, speed, distance and ride times with that friend for up to 4 hours, including outside Group Rides. They choose whether to share back. Turn off, remove or block to stop."
                         : "Live sharing with individual friends is not available on this server yet.")
                    if let error = store.friendLive.error { Text(error).foregroundStyle(.red) }
                }
                if !store.requests.isEmpty {
                    Section("Friend requests") {
                        ForEach(store.requests.filter { $0.status == "pending" }) { request in
                            if request.sender == store.profile?.id {
                                Text("Friend request sent").foregroundStyle(.secondary)
                                Button("Cancel request") { perform { try await store.mutate("friend-requests/\(request.id)", method: "DELETE") } }
                            } else {
                                VStack(alignment: .leading) {
                                    SocialRequestIdentity(store: store, id: request.sender)
                                    HStack {
                                        Button("Accept") { perform { try await store.mutate("friend-requests/\(request.id)/accept") } }
                                        Button("Decline", role: .destructive) { perform { try await store.mutate("friend-requests/\(request.id)/decline") } }
                                    }.buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }
                if !store.invitations.isEmpty {
                    Section("Ride invitations") {
                        ForEach(store.invitations) { invite in
                            NavigationLink(invite.title ?? "Group Ride") {
                                SocialInvitationDetail(store: store, invite: invite)
                            }
                        }
                    }
                }
                if !store.blocked.isEmpty {
                    Section("Blocked riders") {
                        ForEach(store.blocked) { profile in
                            Button("Unblock \(profile.displayName)") { perform { try await store.mutate("blocks/\(profile.id)", method: "DELETE") } }
                        }
                    }
                }
                if store.capabilities.groups {
                    Section("Join a Group Ride") {
                        TextField("Ride code", text: $joinCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Join") { perform { try await store.join(joinCode.trimmingCharacters(in: .whitespacesAndNewlines)) } }
                        Text("Joining shares your live location, speed, distance and times with this group. You can stop sharing at any time.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("Sign out") { perform { try await store.signOut() } }
                    Button("Delete Bicino account", role: .destructive) { deleting = true }
                } footer: {
                    Text("Account deletion applies to bicino.com and social riding. It removes shared content and photos. Your private Health workouts and local routes are not deleted.")
                }
                if let profile = store.profile {
                    SocialPrivacySettingsSections(store: store, profile: profile)
                        .id(profile.id)
                }
            }
            if let notice = store.notice { Section { Text(notice) } }
            if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Profile, Friends & Group Rides")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showsQRCode) {
            if let profile = store.profile {
                SocialQRCode(url: URL(string: "https://bicino.com/social/profile/\(profile.id)")!)
            }
        }
        .onChange(of: store.session.generation) { _ in showsQRCode = false }
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .task(id: store.session.generation) {
            guard store.session.state == .signedIn else { return }
            do { try await store.refresh() }
            catch { store.error = error.localizedDescription }
        }
        .modifier(SocialProfileSetupPresentation(store: store, enabled: offersProfileSetup))
        .refreshable { do { try await store.refresh() } catch { store.error = error.localizedDescription } }
        .alert("Live sharing", isPresented: Binding(
            get: { sharingError != nil }, set: { if !$0 { sharingError = nil } }
        )) {
            Button("OK", role: .cancel) { sharingError = nil }
        } message: { Text(sharingError ?? "") }
        .confirmationDialog("Delete your Bicino account and shared data?", isPresented: $deleting) {
            Button("Delete account", role: .destructive) { perform { try await store.deleteAccount() } }
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true; store.error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await work() } catch SocialFailure.cancelled { } catch { store.error = error.localizedDescription }
        }
    }

    private func setFriendSharing(_ enabled: Bool, with id: String) {
        Task { @MainActor in
            do { try await store.friendLive.setSharing(enabled, with: id) }
            catch SocialFailure.cancelled { }
            catch { sharingError = error.localizedDescription }
        }
    }

    private func searchForRider() {
        let query = username
        guard !busy, !SocialUsername.normalized(query).isEmpty else { return }
        perform { found = try await store.lookup(query) }
    }
}

struct SocialAvatar: View {
    let profile: SocialProfile
    let image: UIImage?
    var body: some View {
        ZStack {
            Circle().fill(Color.blue.opacity(0.18))
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Text(profile.initials.isEmpty ? "?" : profile.initials).font(.headline) }
        }.frame(width: 40, height: 40).clipShape(Circle()).accessibilityLabel(profile.displayName)
    }
}

private struct SocialRequestIdentity: View {
    @ObservedObject var store: SocialCoordinator
    let id: String
    @State private var name = "Bicino rider"
    var body: some View {
        Text(name).task {
            if let data = try? await store.client.request("profiles/\(id)"),
               let profile = try? JSONDecoder().decode(SocialProfile.self, from: data) { name = profile.displayName }
        }
    }
}

private struct SocialFriendView: View {
    @ObservedObject var store: SocialCoordinator
    let friend: SocialProfile
    let routeLibrary: PhoneRouteLibrary
    @State private var routes: [SocialContent] = []
    @State private var activities: [SocialContent] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Section {
                SocialAvatar(profile: friend, image: friend.avatarID.flatMap { store.photos[$0] })
                if let username = friend.username, !username.isEmpty {
                    Text("@\(username)").textSelection(.enabled)
                }
            }
            if store.visibleRiders.contains(where: { $0.id == friend.id }) {
                Section("Live ride data") { SocialRideMemberRow(profile: friend, store: store, includesFriendSharing: true) }
            }
            Section("Routes") {
                ForEach(routes) { route in NavigationLink(route.title) { SocialContentDetail(store: store, item: route, routeLibrary: routeLibrary) } }
            }
            Section("Completed rides") {
                ForEach(activities) { item in NavigationLink(item.title) { SocialContentDetail(store: store, item: item, routeLibrary: routeLibrary) } }
            }
            Section {
                Button("Remove friend", role: .destructive) { remove(block: false) }
                Button("Block rider", role: .destructive) { remove(block: true) }
            } footer: { Text("Removing a friend does not leave an accepted ride. Blocking stops mutual live visibility and may leave a shared ride.") }
        }.navigationTitle(friend.displayName)
        .task {
            do { routes = try await store.content(kind: "routes", owner: friend.id)
                activities = try await store.content(kind: "activities", owner: friend.id)
            } catch { store.error = error.localizedDescription }
        }
    }
    private func remove(block: Bool) {
        Task { do { try await store.removeFriend(friend.id, block: block); dismiss() } catch { store.error = error.localizedDescription } }
    }
}

struct SocialVisibilityPicker: View {
    @Binding var selection: String
    var body: some View {
        Picker("Who can see this?", selection: $selection) {
            Text("Only me").tag("private")
            Text("Friends").tag("friends")
            Text("Anyone with link").tag("link")
        }
    }
}

struct SocialContentDetail: View {
    @ObservedObject var store: SocialCoordinator
    @State var item: SocialContent
    let routeLibrary: PhoneRouteLibrary
    @State private var visibility = "private"
    @State private var shareURL: URL?
    @State private var saved = false
    @State private var loaded = false
    @State private var schedule = false
    @State private var startsAt = Date()
    var body: some View {
        List {
            SocialTrackPreview(content: item.body).frame(height: 260)
            if let meters = item.body.distanceMeters { Text("Visible distance: \(Int(meters)) m") }
            if let moving = item.body.movingSeconds { Text("Moving time: \(Int(moving / 60)) min") }
            if item.kind == "route" {
                Button(saved ? "Saved to route library" : "Save route") {
                    do { try store.save(item, to: routeLibrary); saved = true } catch { store.error = error.localizedDescription }
                }
                Button("Duplicate route") {
                    do { try store.save(item, to: routeLibrary, duplicate: true); saved = true }
                    catch { store.error = error.localizedDescription }
                }
                if store.capabilities.groups && item.owner == store.profile?.id {
                    Toggle("Schedule for later", isOn: $schedule)
                    if schedule { DatePicker("Starts", selection: $startsAt, in: Date()...Date().addingTimeInterval(29 * 86400)) }
                    Button("Ride together") {
                        Task { do { try await store.createRide(route: item, title: item.title, startsAt: schedule ? startsAt : nil) } catch { store.error = error.localizedDescription } }
                    }
                }
                Text("A saved copy stays in your library even if the owner later stops sharing.").font(.caption)
            }
            if let segments = item.body.segments {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, points in
                    Button("Save visible segment \(index + 1) as route") { run {
                        let coordinates = points.map { "<trkpt lat=\"\($0.latitude)\" lon=\"\($0.longitude)\"/>" }.joined()
                        let gpx = "<?xml version=\"1.0\"?><gpx version=\"1.1\" creator=\"Bicino\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><trkseg>" + coordinates + "</trkseg></trk></gpx>"
                        _ = try routeLibrary.importGPX(Data(gpx.utf8), fileName: "Shared ride segment \(index + 1).gpx")
                        saved = true
                    } }
                }
                Text("Each visible section becomes a separate route. Hidden areas are never joined or reconstructed.").font(.caption)
            }
            if item.owner == store.profile?.id {
                SocialVisibilityPicker(selection: $visibility)
                Button("Save visibility") { run {
                    let value = try await store.client.json("\(item.kind == "route" ? "routes" : "activities")/\(item.id)", method: "PATCH",
                        body: ["revision": item.revision, "title": item.title, "visibility": visibility])
                    item = try JSONDecoder().decode(SocialContent.self, from: JSONSerialization.data(withJSONObject: value))
                    try await store.refresh()
                } }
                if item.visibility == "link" {
                    Button("Create share link") { run {
                        let value = try await store.client.json("share-links", method: "POST", body: ["contentID": item.id])
                        shareURL = (value["url"] as? String).flatMap(URL.init(string:))
                    } }
                    if let shareURL { ShareLink(item: shareURL) }
                }
                Text("Changing visibility to Only me revokes existing share links.").font(.caption)
            }
            if let error = store.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle(item.title).disabled(!loaded).task {
            do {
                if item.body.archive == nil && item.body.segments == nil && item.body.needsReprocessing != true {
                    item = try JSONDecoder().decode(SocialContent.self,
                        from: await store.client.request("\(item.kind == "route" ? "routes" : "activities")/\(item.id)"))
                }
                visibility = item.visibility
                loaded = true
            } catch { store.error = error.localizedDescription }
        }
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task { do { try await work() } catch { store.error = error.localizedDescription } }
    }
}

private struct SocialLiveControls: View {
    @Environment(\.savedRouteMapAction) private var mapAction
    @ObservedObject var store: SocialCoordinator
    let routeLibrary: PhoneRouteLibrary
    var body: some View {
        if let ride = store.live.ride {
            Text(ride.title).font(.headline)
            Text("\(ride.members.count) \(ride.members.count == 1 ? "rider" : "riders")")
            if store.live.isSharing {
                Button("Stop sharing", role: .destructive) { Task { await store.live.stopSharing() } }
            }
            Button("Save shared route") { run { try store.saveRideRoute(ride, to: routeLibrary) } }
            if let mapAction {
                Button("Open shared route on map") { run {
                    let summary = try store.saveRideRoute(ride, to: routeLibrary)
                    try mapAction.perform { try routeLibrary.mapSelection(for: summary) }
                } }
            }
            ForEach(ride.members.filter { $0.id != store.profile?.id }) { member in
                SocialRideMemberRow(profile: member, store: store)
            }
            if let url = store.live.invitationURL { ShareLink("Invite with link", item: url) }
            if ride.owner == store.profile?.id {
                if store.live.invitationCode == nil {
                    Button("Create invite link") { run { try await store.live.rotateInvitation() } }
                        .disabled(store.live.isRotatingInvitation)
                }
                ForEach(store.friends) { friend in
                    if let invite = store.sentInvitations.first(where: { $0.ride == ride.id && $0.recipient == friend.id }) {
                        Button("Cancel invitation to \(friend.displayName)") { run { try await store.mutate("ride-invites/\(invite.id)", method: "DELETE") } }
                    } else {
                        Button("Invite \(friend.displayName)") { run { try await store.mutate("ride-invites", body: ["rideID": ride.id, "profileID": friend.id]) } }
                    }
                }
                ForEach(ride.members.filter { $0.id != ride.owner }) { member in
                    Button("Remove \(member.displayName)", role: .destructive) { run { try await store.mutate("group-rides/\(ride.id)/members/\(member.id)", method: "DELETE") } }
                }
                Button("End Group Ride", role: .destructive) { run { try await store.live.leave(end: true) } }
            }
            Menu("Send status") {
                ForEach(["waiting", "mechanical", "turned_around", "regroup", "meet_at_stop"], id: \.self) { status in
                    Button(status.replacingOccurrences(of: "_", with: " ").capitalized) { run { try await store.live.send(status) } }
                }
            }
            ForEach(store.live.messages) { message in Text(message.status.replacingOccurrences(of: "_", with: " ")).font(.caption) }
            Button("Leave ride", role: .destructive) { run { try await store.live.leave() } }
            if let error = store.live.error { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task { do { try await work() } catch { store.error = error.localizedDescription } }
    }
}

struct SocialTrackPreview: UIViewRepresentable {
    let content: SocialContentBody
    func makeUIView(context: Context) -> MKMapView { let map = MKMapView(); map.delegate = context.coordinator; return map }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func updateUIView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        var segments = content.segments?.map { $0.map(\.coordinate) } ?? []
        if let archive = content.archive,
           let route = try? NavigationRouteArchiveV1.decode(Data(archive.utf8), purpose: .offlineNavigation) {
            segments = [route.route.points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }]
        }
        var bounds = MKMapRect.null
        for segment in segments where segment.count > 1 {
            let coords = segment.map { CoordinateConverter.wgs84ToGCJ02(coordinate: $0) }
            let line = MKPolyline(coordinates: coords, count: coords.count)
            map.addOverlay(line); bounds = bounds.union(line.boundingMapRect)
        }
        if !bounds.isNull { map.setVisibleMapRect(bounds, edgePadding: UIEdgeInsets(top: 20, left: 20, bottom: 20, right: 20), animated: false) }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let renderer = MKPolylineRenderer(overlay: overlay); renderer.strokeColor = .systemBlue; renderer.lineWidth = 4; return renderer
        }
    }
}

private struct SocialInvitationDetail: View {
    @ObservedObject var store: SocialCoordinator
    @State var invite: SocialInvite
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Text(invite.title ?? "Group Ride").font(.headline)
            if let start = invite.startsAt { Text(Date(timeIntervalSince1970: start).formatted(date: .abbreviated, time: .shortened)) }
            if let route = invite.route { SocialTrackPreview(content: route).frame(height: 250) }
            Text("Joining shares your live location, speed, distance and times with riders in this group.").font(.caption).foregroundStyle(.secondary)
            Button("Join ride") { Task {
                do { try await store.acceptInvite(invite.id); dismiss() }
                catch { store.error = error.localizedDescription }
            } }.disabled(invite.route == nil)
            Button("Decline") { Task {
                do { try await store.mutate("ride-invites/\(invite.id)/decline"); dismiss() }
                catch { store.error = error.localizedDescription }
            } }
            if let error = store.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Ride invitation").task {
            do { invite = try JSONDecoder().decode(SocialInvite.self,
                from: await store.client.request("ride-invites/\(invite.id)")) }
            catch { store.error = error.localizedDescription }
        }
    }
}
