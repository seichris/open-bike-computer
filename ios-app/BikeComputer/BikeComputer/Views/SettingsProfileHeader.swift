import SwiftUI

struct SettingsProfileHeader: View {
    let profile: SocialProfile?
    let image: UIImage?
    let isSignedIn: Bool
    let isRestoring: Bool

    var body: some View {
        VStack(spacing: 8) {
            SocialProfilePortrait(profile: profile, image: image, size: 80)
            if let profile, isSignedIn {
                Text(profile.displayName).font(.title2.weight(.semibold))
                if let username = profile.username, !username.isEmpty {
                    Text("@\(username)").font(.subheadline).foregroundStyle(.secondary)
                }
                if profile.needsProfileSetup {
                    Text("Complete your profile").font(.subheadline).foregroundStyle(.tint)
                }
            } else if isRestoring || isSignedIn {
                Text("Your Bicino account").font(.title2.weight(.semibold))
                Text("Loading your profile…").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("Sign in to Bicino").font(.title2.weight(.semibold))
                Text("Connect with friends and ride together")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SocialProfilePortrait: View {
    let profile: SocialProfile?
    let image: UIImage?
    var size: CGFloat = 80

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.12))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let profile, !profile.initials.isEmpty {
                Text(profile.initials).font(.system(size: size * 0.35, weight: .semibold))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.42)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

#Preview("Signed out") {
    SettingsProfileHeader(profile: nil, image: nil, isSignedIn: false, isRestoring: false)
}

#Preview("Profile") {
    SettingsProfileHeader(
        profile: SocialProfile(id: "preview", username: "chris", displayName: "Chris",
            avatarID: nil, version: 1, privacy: nil),
        image: nil, isSignedIn: true, isRestoring: false
    )
}

#Preview("Incomplete profile · Large text") {
    SettingsProfileHeader(
        profile: SocialProfile(id: "preview", username: nil, displayName: "Rider",
            avatarID: nil, version: 1, privacy: nil),
        image: nil, isSignedIn: true, isRestoring: false
    ).environment(\.dynamicTypeSize, .accessibility3)
}
