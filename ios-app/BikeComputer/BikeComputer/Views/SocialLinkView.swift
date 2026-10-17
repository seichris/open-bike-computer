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
    @State private var profile: SocialProfile?
    @State private var content: SocialContent?
    @State private var preview: SocialRidePreview?
    @State private var error: String?
    @State private var completed = false
    var body: some View {
        Group {
            if store.session.state != .signedIn {
                SocialHubView(store: store, routeLibrary: routeLibrary)
            } else if let content {
                SocialContentDetail(store: store, item: content, routeLibrary: routeLibrary)
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
                        Text("Joining does not start location sharing.")
                        Button("Join ride") { run {
                            guard let code = store.pendingLink?.lastPathComponent else { return }
                            try await store.join(code); completed = true
                        } }.disabled(completed)
                    }
                    if completed { Text("Done. Open Friends & Riding to continue.") }
                    if let error { Text(error).foregroundStyle(.red) }
                }.navigationTitle("Bicino link")
            }
        }.task(id: store.session.state) {
            guard store.session.state == .signedIn, let url = store.pendingLink else { return }
            run {
                let parts = url.pathComponents
                guard parts.count == 4 else { throw SocialFailure.invalidResponse }
                let id = parts[3]
                guard id.range(of: "^[A-Za-z0-9_-]{20,100}$", options: .regularExpression) != nil else { throw SocialFailure.invalidResponse }
                switch parts[2] {
                case "profile": profile = try JSONDecoder().decode(SocialProfile.self, from: await store.client.request("profiles/\(id)"))
                case "shared": content = try JSONDecoder().decode(SocialContent.self, from: await store.client.request("shared/\(id)"))
                case "ride": preview = try JSONDecoder().decode(SocialRidePreview.self, from: await store.client.request("group-rides/preview/\(id)"))
                default: throw SocialFailure.invalidResponse
                }
            }
        }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        Task { do { try await action() } catch { self.error = error.localizedDescription } }
    }
}
private struct SocialRidePreview: Decodable { let title: String; let route: SocialContentBody }
