import Foundation

enum SocialPrivacyFlag: Sendable {
    case requests, invitations, notifications, friendNotifications, rideNotifications

    var keyPath: WritableKeyPath<SocialPrivacy, Bool> {
        switch self {
        case .requests: \.requests
        case .invitations: \.invitations
        case .notifications: \.notifications
        case .friendNotifications: \.friendNotifications
        case .rideNotifications: \.rideNotifications
        }
    }
}

enum SocialUsername {
    static func normalized(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
    }
}

extension SocialProfile {
    /// A photo is optional. A chosen name and username complete the profile.
    var needsProfileSetup: Bool {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct SocialProfileDraft {
    var name: String
    var username: String

    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var normalizedUsername: String { username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var isValid: Bool {
        !normalizedName.isEmpty && normalizedName.count <= 80
            && normalizedUsername.range(of: "^[a-z][a-z0-9_]{2,29}$", options: .regularExpression) != nil
    }

    init(profile: SocialProfile) {
        name = profile.username == nil && profile.displayName == "Rider" ? "" : profile.displayName
        username = profile.username ?? ""
    }
}

/// Local presentation history only; public profile data stays on the service.
struct SocialProfileSetupHistory {
    let defaults: UserDefaults

    func shouldOffer(for profile: SocialProfile) -> Bool {
        profile.needsProfileSetup && !defaults.bool(forKey: key(profile.id))
    }

    func recordOffer(for profile: SocialProfile) {
        defaults.set(true, forKey: key(profile.id))
    }

    private func key(_ id: String) -> String { "bicino.social.profileSetup.offered.\(id)" }
}
