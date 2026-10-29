import CoreImage.CIFilterBuiltins
import SwiftUI

struct SocialQRCode: View {
    let url: URL
    private var image: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    var body: some View {
        VStack(spacing: 24) {
            if let image { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().padding().background(.white).accessibilityLabel("QR code for this Bicino link") }
            ShareLink("Share link", item: url)
        }.padding().navigationTitle("Bicino QR code")
    }
}

struct SocialLinkView: View {
    @ObservedObject var store: SocialCoordinator
    let routeLibrary: PhoneRouteLibrary
    @StateObject private var loader: SocialLinkLoader
    @State private var error: String?
    @State private var completed = false

    init(store: SocialCoordinator, routeLibrary: PhoneRouteLibrary) {
        self.store = store
        self.routeLibrary = routeLibrary
        _loader = StateObject(wrappedValue: SocialLinkLoader(client: store.client,
            currentGeneration: { store.session.generation }))
    }

    private var profile: SocialProfile? {
        if case .profile(let value) = loader.value(for: store.pendingLink) { return value }
        return nil
    }
    private var content: SocialContent? {
        if case .content(let value) = loader.value(for: store.pendingLink) { return value }
        return nil
    }
    private var preview: SocialRidePreview? {
        if case .ride(let value) = loader.value(for: store.pendingLink) { return value }
        return nil
    }
    private var loadID: String { "\(store.session.generation)|\(store.session.state)|\(store.pendingLink?.absoluteString ?? "")" }
    var body: some View {
        Group {
            if store.session.state != .signedIn {
                SocialHubView(store: store, routeLibrary: routeLibrary, offersProfileSetup: false)
            } else if let content {
                SocialContentDetail(store: store, item: content, routeLibrary: routeLibrary)
                    .id(loadID)
            } else {
                List {
                    if let profile {
                        Text(profile.displayName).font(.headline)
                        Text(profile.username.map { "@\($0)" } ?? "Bicino rider")
                        Button("Send friend request") { run { try await store.mutate("friend-requests", body: ["profileID": profile.id]); completed = true } }.disabled(completed)
                    }
                    if let preview {
                        Text(preview.title).font(.headline)
                        SocialTrackPreview(content: preview.route).frame(height: 250)
                        Text("Joining shares your live location, speed, distance and times with riders in this group.")
                        Button("Join ride") { run {
                            guard let url = store.pendingLink, let target = SocialLinkTarget(url: url), target.kind == "ride" else { return }
                            let code = target.id
                            try await store.join(code); completed = true
                        } }.disabled(completed)
                    }
                    if completed { Text("Done. Open your profile to continue.") }
                    if let error { Text(error).foregroundStyle(.red) }
                }.navigationTitle("Bicino link")
            }
        }
        .modifier(SocialProfileSetupPresentation(store: store))
        .task(id: loadID) {
            loader.reset(); completed = false; error = nil
            guard store.session.state == .signedIn, let url = store.pendingLink else { return }
            let generation = store.session.generation
            do {
                try await store.refresh()
                guard generation == store.session.generation, url == store.pendingLink, !Task.isCancelled else { return }
                try await loader.load(url)
            } catch {
                guard generation == store.session.generation, url == store.pendingLink, !Task.isCancelled else { return }
                self.error = error.localizedDescription
                }
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        let generation = store.session.generation
        Task {
            guard generation == store.session.generation else { return }
            do { try await action() } catch {
                if generation == store.session.generation { self.error = error.localizedDescription }
            }
        }
    }
}
