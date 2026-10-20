import SwiftUI

struct SocialProfileActionsRow: View {
    let profileURL: URL
    let showQRCode: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ShareLink("Share my profile", item: profileURL)
                .labelStyle(.titleOnly)
            Button(action: showQRCode) {
                Image(systemName: "qrcode")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Show my QR code")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.blue)
        .tint(.blue)
    }
}

struct SocialRiderSearchRow: View {
    @Binding var username: String
    let search: () -> Void

    var body: some View {
        HStack {
            TextField("@username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(search)
                .accessibilityLabel("Rider username")
            Button("Search", action: search)
                .fixedSize()
                .buttonStyle(.borderless)
                .disabled(SocialUsername.normalized(username).isEmpty)
        }
    }
}

#Preview("Profile actions") {
    Form {
        SocialProfileActionsRow(profileURL: URL(string: "https://bicino.com/social/profile/preview")!,
            showQRCode: {})
        SocialRiderSearchRow(username: .constant(""), search: {})
    }
}
