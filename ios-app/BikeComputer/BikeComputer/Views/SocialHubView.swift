import PhotosUI
import SwiftUI
import MapKit

struct SocialHubView: View {
    @ObservedObject var store: SocialCoordinator
    @ObservedObject var routeLibrary: PhoneRouteLibrary
    @State private var username = ""
    @State private var found: SocialProfile?
    @State private var joinCode = ""
    @State private var busy = false
    @State private var deleting = false

    var body: some View {
        List {
            if store.session.state == .unavailable {
                Section { Text("Social riding is not available in this build. Navigation and private workouts are still available.") }
            } else if store.session.state != .signedIn {
                Section("Your Bicino account") {
                    Text("Use the same Apple or Google account as bicino.com.")
                    Button("Continue with Apple") { perform { _ = try await store.session.signInWithApple(); try await store.refresh() } }
                    Button("Continue with Google") { perform { try await store.session.signInWithGoogle(); try await store.refresh() } }
                }
            } else {
                if let profile = store.profile {
                    Section {
                        NavigationLink {
                            SocialProfileEditor(store: store, profile: profile)
                        } label: {
                            HStack {
                                SocialAvatar(profile: profile, image: profile.avatarID.flatMap { store.photos[$0] })
                                VStack(alignment: .leading) {
                                    Text(profile.displayName)
                                    Text(profile.username.map { "@\($0)" } ?? "Set your username and photo").font(.caption)
                                }
                            }
                        }
                        NavigationLink("Show my QR code") { SocialQRCode(url: URL(string: "https://bicino.com/social/profile/\(profile.id)")!) }
                        ShareLink(item: URL(string: "https://bicino.com/social/profile/\(profile.id)")!) {
                            Label("Share my profile", systemImage: "qrcode")
                        }
                    }
                }
                if store.live.ride != nil {
                    Section("Group Ride") { SocialLiveControls(store: store, routeLibrary: routeLibrary) }
                }
                if !store.rides.isEmpty {
                    Section("My Group Rides") {
                        ForEach(store.rides.filter { $0.id != store.live.ride?.id }) { ride in
                            Button(ride.title) { perform { try await store.live.select(ride) } }
                        }
                    }
                }
                Section("Friends") {
                    ForEach(store.friends) { friend in
                        NavigationLink {
                            SocialFriendView(store: store, friend: friend, routeLibrary: routeLibrary)
                        } label: {
                            HStack {
                                SocialAvatar(profile: friend, image: friend.avatarID.flatMap { store.photos[$0] })
                                Text(friend.displayName)
                            }
                        }
                    }
                    TextField("Exact username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Find rider") { perform { found = try await store.lookup(username.lowercased()) } }
                    if let found {
                        Text(found.displayName)
                        Button("Send friend request") { perform { try await store.mutate("friend-requests", body: ["profileID": found.id]); self.found = nil } }
                    }
                }
                if !store.requests.isEmpty {
                    Section("Friend requests") {
                        ForEach(store.requests) { request in
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
                if store.capabilities.routes {
                    Section("Shared routes") {
                        NavigationLink("Publish a saved route") { SocialRoutePublisher(store: store, routeLibrary: routeLibrary) }
                        ForEach(store.routes) { route in
                            NavigationLink(route.title) { SocialContentDetail(store: store, item: route, routeLibrary: routeLibrary) }
                        }
                    }
                }
                if store.capabilities.activities {
                    Section("Completed rides") {
                        NavigationLink("Share a completed ride") { SocialActivityPublisher(store: store) }
                        ForEach(store.activities) { activity in
                            NavigationLink(activity.title) { SocialContentDetail(store: store, item: activity, routeLibrary: routeLibrary) }
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
                    }
                }
                Section {
                    Button("Link another Google sign-in") { perform { try await store.session.signInWithGoogle(link: true) } }
                    Button("Link another Apple sign-in") { perform { _ = try await store.session.signInWithApple(link: true) } }
                    Text("Link a provider only if it belongs to you. Accounts with existing separate identities are never merged automatically.").font(.caption)
                    Button("Enable request and invitation alerts") { perform { try await store.enableNotifications() } }
                    Button("Sign out") { perform { try await store.signOut() } }
                    Button("Delete Bicino account", role: .destructive) { deleting = true }
                } footer: {
                    Text("Account deletion applies to bicino.com and social riding. It removes shared content and photos. Your private Health workouts and local routes are not deleted.")
                }
            }
            if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle("Friends & Riding")
        .disabled(busy)
        .overlay { if busy { ProgressView() } }
        .task { if store.session.state == .signedIn { perform { try await store.refresh() } } }
        .refreshable { do { try await store.refresh() } catch { store.error = error.localizedDescription } }
        .confirmationDialog("Delete your Bicino account and shared data?", isPresented: $deleting) {
            Button("Delete account", role: .destructive) { perform { try await store.deleteAccount() } }
        }
        .onChange(of: store.pendingLink) { url in
            guard let url else { return }
            let parts = url.pathComponents
            if parts.count == 4 && parts[2] == "ride" { joinCode = parts[3] }
        }
    }

    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true; store.error = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await work() } catch { store.error = error.localizedDescription }
        }
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

private struct SocialProfileEditor: View {
    @ObservedObject var store: SocialCoordinator
    let profile: SocialProfile
    @State private var username = ""
    @State private var name = ""
    @State private var privacy = SocialPrivacy()
    @State private var selected: PhotosPickerItem?
    @State private var photo: Data?
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var radius = "500"
    var body: some View {
        Form {
            Section {
                TextField("Display name", text: $name)
                TextField("Username", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                if store.capabilities.media {
                    PhotosPicker("Choose photo", selection: $selected, matching: .images)
                    if let photo, let image = UIImage(data: photo) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 160, height: 160).clipShape(Circle())
                        Button("Use this photo") { run { try await store.setPhoto(photo); self.photo = nil } }
                    }
                }
                Button("Remove photo", role: .destructive) { run { try await store.removePhoto() } }
            } header: { Text("Profile") } footer: {
                Text("Your name and photo are visible to riders who look up your exact profile, friends, and accepted ride members. Your location stays private until you share it in a ride.")
            }
            Section("Privacy and notifications") {
                Toggle("Allow friend requests", isOn: $privacy.requests)
                Toggle("Allow ride invitations from friends", isOn: $privacy.invitations)
                Toggle("Notifications", isOn: $privacy.notifications)
                Toggle("Friend request notifications", isOn: $privacy.friendNotifications)
                Toggle("Ride invitation notifications", isOn: $privacy.rideNotifications)
                Text("Routes and completed rides start as Only me. Sharing a route never shares your live location.")
            }
            Section("Private areas") {
                ForEach(Array(privacy.zones.enumerated()), id: \.offset) { index, zone in
                    HStack { Text("Private area \(index+1) · \(Int(zone.radius)) m"); Spacer()
                        Button("Remove", role: .destructive) { privacy.zones.remove(at: index) }
                    }
                }
                TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
                TextField("Radius in metres (200–20000)", text: $radius).keyboardType(.numberPad)
                Button("Add private area") {
                    guard privacy.zones.count < 10, let lat = Double(latitude), let lon = Double(longitude),
                          let radius = Double(radius), (-90...90).contains(lat), (-180...180).contains(lon),
                          (200...20000).contains(radius) else { store.error = "Enter valid coordinates and radius."; return }
                    privacy.zones.append(.init(latitude: lat, longitude: lon, radius: radius))
                }
                Text("Changing private areas hides previously published rides until you share them again. Start and finish areas are trimmed automatically.").font(.caption)
            }
            Button("Save profile and privacy") { run { try await store.saveProfile(username: username, name: name, privacy: privacy) } }
            if let error = store.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Your profile")
        .task { username = profile.username ?? ""; name = profile.displayName; privacy = profile.privacy ?? SocialPrivacy() }
        .onChange(of: selected) { item in
            Task { photo = try? await item?.loadTransferable(type: Data.self) }
        }
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        Task { do { try await work() } catch { store.error = error.localizedDescription } }
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
            Section { SocialAvatar(profile: friend, image: friend.avatarID.flatMap { store.photos[$0] }) }
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

private struct SocialRoutePublisher: View {
    @ObservedObject var store: SocialCoordinator
    @ObservedObject var routeLibrary: PhoneRouteLibrary
    @State private var visibility = "private"
    @State private var consent = false
    @State private var selected: PlannedRouteSummaryV1?
    var body: some View {
        List {
            Section { SocialVisibilityPicker(selection: $visibility)
                Toggle("I have permission to share this route", isOn: $consent)
                Text("Planned routes are shared exactly as saved, including any private areas they cross. Review the whole route before sharing. Only eligible GPX routes can be published.").font(.caption)
            }
            ForEach(routeLibrary.offlineNavigationRoutes.filter { $0.providerID == "user.imported-gpx" }) { route in
                Button(route.name) { selected = route }
            }
            if let selected, let archive = try? routeLibrary.offlineArchive(for: selected),
               let encoded = try? archive.encoded(purpose: .offlineNavigation),
               let body = try? JSONDecoder().decode(SocialContentBody.self, from: JSONSerialization.data(withJSONObject: ["archive": String(decoding: encoded, as: UTF8.self)])) {
                SocialTrackPreview(content: body).frame(height: 230)
                Button("Publish \(selected.name)") {
                    Task { do { try await store.publish(archive, title: selected.name, visibility: visibility) }
                        catch { store.error = error.localizedDescription } }
                }.disabled(!consent)
            }
            if let error = store.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Share route")
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
                if store.capabilities.groups {
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
    @State private var stats = false
    var body: some View {
        if let ride = store.live.ride {
            Text(ride.title).font(.headline)
            Text("\(ride.members.count) riders · Sharing \(store.live.isSharing ? "on" : "off")")
            if store.live.isSharing {
                Button("Stop sharing", role: .destructive) { Task { await store.live.stopSharing() } }
            } else {
                Toggle("Share GPS speed, distance and times", isOn: $stats)
                Button("Share my live location") { run { try await store.live.startSharing(stats: stats) } }
            }
            Button("Save shared route") { run {
                guard let raw = ride.route.archive else { throw SocialFailure.invalidResponse }
                _ = try routeLibrary.importArchive(Data(raw.utf8))
            } }
            if let mapAction {
                Button("Open shared route on map") { run {
                    guard let raw = ride.route.archive else { throw SocialFailure.invalidResponse }
                    let summary = try routeLibrary.importArchive(Data(raw.utf8))
                    try mapAction.perform { try routeLibrary.mapSelection(for: summary) }
                } }
            }
            ForEach(store.live.riders.filter { $0.id != store.profile?.id }) { rider in
                VStack(alignment: .leading) {
                    HStack {
                        SocialAvatar(profile: rider.profile, image: rider.profile.avatarID.flatMap { store.photos[$0] })
                        Text(rider.profile.displayName)
                    }
                    if let speed = rider.speed { Text(String(format: "%.1f km/h", speed * 3.6)) }
                    if let distance = rider.distanceMeters { Text(String(format: "Ride distance: %.1f km", distance / 1000)) }
                    if let own = store.live.riders.first(where: { $0.id == store.profile?.id }),
                       own.age(at: Date()) < 15, rider.age(at: Date()) < 15,
                       let ownProgress = own.routeProgressMeters, let progress = rider.routeProgressMeters,
                       own.routeHash == rider.routeHash {
                        let gap = progress - ownProgress
                        Text("\(Int(abs(gap))) m \(gap >= 0 ? "ahead" : "behind") along the shared route").font(.caption)
                    } else { Text("Route gap unavailable").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if let code = store.live.invitationCode, let url = URL(string: "https://bicino.com/social/ride/\(code)") { ShareLink("Invite with link", item: url) }
            if ride.owner == store.profile?.id {
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
            Text("Joining does not share your location.")
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
