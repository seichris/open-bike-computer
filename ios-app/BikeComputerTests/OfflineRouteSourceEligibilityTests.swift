import Foundation

@main
struct OfflineRouteSourceEligibilityTests {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var checks = 0
        func check(_ condition: Bool) {
            precondition(condition)
            checks += 1
        }
        for provider: RouteProviderMetadataV1? in [nil, RouteProviderPolicyV1.mapKit,
            RouteProviderMetadataV1(providerID: "unreviewed", attribution: "Unknown", storageScope: .durable),
            RouteProviderMetadataV1(providerID: "apple.mapkit", attribution: "Apple Maps", storageScope: .durable),
            RouteProviderMetadataV1(providerID: "user.imported-gpx", attribution: "Spoofed", storageScope: .durable)] {
            for expiry in [nil, now.addingTimeInterval(1), now] {
                check(!OfflineRouteSourceEligibilityV1.allowsSave(provider: provider, deleteAfter: expiry, now: now))
            }
        }
        check(OfflineRouteSourceEligibilityV1.allowsSave(provider: RouteProviderPolicyV1.importedGPX, now: now))
        check(!OfflineRouteSourceEligibilityV1.allowsSave(provider: RouteProviderPolicyV1.strava, now: now))
        for provider in [RouteProviderPolicyV1.importedGPX, RouteProviderPolicyV1.strava] {
            check(OfflineRouteSourceEligibilityV1.allowsSave(provider: provider, deleteAfter: now.addingTimeInterval(1), now: now))
            check(!OfflineRouteSourceEligibilityV1.allowsSave(provider: provider, deleteAfter: now, now: now))
            check(!OfflineRouteSourceEligibilityV1.allowsSave(provider: provider, deleteAfter: now.addingTimeInterval(-1), now: now))
            check(!OfflineRouteSourceEligibilityV1.allowsSave(provider: provider, deleteAfter: Date(timeIntervalSince1970: .nan), now: now))
            check(!OfflineRouteSourceEligibilityV1.allowsSave(provider: provider, now: Date(timeIntervalSince1970: .infinity)))
        }
        print("Offline route source eligibility: \(checks) checks passed")
    }
}
