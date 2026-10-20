import SwiftUI

struct SocialRideMemberRow: View {
    let profile: SocialProfile
    @ObservedObject var store: SocialCoordinator

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let rider = store.live.riders.first { $0.id == profile.id && $0.age(at: context.date) < 60 }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    SocialAvatar(profile: profile, image: profile.avatarID.flatMap { store.photos[$0] })
                    Text(profile.displayName)
                }
                if let rider {
                    if let speed = rider.speed { Text(String(format: "%.1f km/h", speed * 3.6)) }
                    if let distance = rider.distanceMeters { Text(String(format: "Ride distance: %.1f km", distance / 1000)) }
                    if let moving = rider.movingSeconds { Text("Moving: \(duration(moving))") }
                    if let elapsed = rider.elapsedSeconds { Text("Elapsed: \(duration(elapsed))") }
                    if let own = store.live.riders.first(where: { $0.id == store.profile?.id }),
                       own.age(at: context.date) < 15, rider.age(at: context.date) < 15,
                       let ownProgress = own.routeProgressMeters, let progress = rider.routeProgressMeters,
                       own.routeHash == rider.routeHash {
                        let gap = progress - ownProgress
                        Text("\(Int(abs(gap))) m \(gap >= 0 ? "ahead" : "behind") along the route").font(.caption)
                    }
                } else {
                    Text("Waiting for live location").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func duration(_ seconds: Double) -> String {
        let total = Int(max(0, min(seconds, 7 * 86400)))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }
}
