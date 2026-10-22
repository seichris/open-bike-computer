import Foundation
import MapKit

@MainActor
private final class ControlledPOIProvider: OnlinePOISearchProviding {
    var requests: [Set<OnlinePOICategory>] = []
    var pending: [CheckedContinuation<[MKMapItem], any Error>] = []
    var cancellations = 0

    func search(categories: Set<OnlinePOICategory>, center: CLLocationCoordinate2D,
                radius: CLLocationDistance) async throws -> [MKMapItem] {
        requests.append(categories)
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }

    // Deliberately ignore cancellation to exercise late MapKit completions.
    func cancel() { cancellations += 1 }
}

@main
struct OnlinePOISearchTests {
    @MainActor
    static func main() async throws {
        let center = CLLocationCoordinate2D(latitude: 1.3, longitude: 103.85)
        let region = MKCoordinateRegion(center: center, latitudinalMeters: 2_000,
                                       longitudinalMeters: 2_000)
        func place(_ name: String, latitudeOffset: Double) -> MKMapItem {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(
                latitude: center.latitude + latitudeOffset, longitude: center.longitude)))
            item.name = name
            return item
        }
        let near = place("Cafe", latitudeOffset: 0.001)
        let duplicate = place("Cafe", latitudeOffset: 0.001001)
        let farther = place("Shop", latitudeOffset: 0.005)
        let outside = place("Outside", latitudeOffset: 0.1)
        let filtered = OnlinePOISearchSession.nearbyUniqueItems(
            [farther, near, outside, duplicate], center: center, radius: 1_000)
        precondition(filtered.count == 2 && filtered[0] === near && filtered[1] === farther,
                     "Merge overlapping searches, enforce radius, and sort returned matches")

        let provider = ControlledPOIProvider()
        let session = OnlinePOISearchSession(provider: provider, debounceNanoseconds: 0)
        precondition(session.radius <= MKLocalPointsOfInterestRequest.maxRadius)
        session.toggle(.food, region: region)
        try await wait { provider.pending.count == 1 }
        session.toggle(.shops, region: region)
        try await wait { provider.pending.count == 2 }
        precondition(provider.requests[1] == [.food, .shops], "Selections combine with OR semantics")
        provider.pending[1].resume(returning: [farther])
        try await wait { session.state == .loaded }
        provider.pending[0].resume(returning: [near])
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(session.items.count == 1 && session.items[0] === farther,
                     "An older completion cannot replace the current category batch")
        session.select(near)
        precondition(session.selectedItem == nil, "Ignore pins outside the current result set")
        session.select(farther)
        precondition(session.selectedItem === farther)
        session.clear()
        precondition(!session.isActive && session.items.isEmpty && session.selectedItem == nil)
        precondition(session.center == nil && session.state == .idle)

        session.toggle(.toilets, region: region)
        try await wait { provider.pending.count == 3 }
        session.clear()
        provider.pending[2].resume(returning: [near])
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(session.items.isEmpty && session.state == .idle,
                     "Dismissal releases data and fences in-flight callbacks")
        session.toggle(.fuel, region: nil)
        precondition(provider.requests.count == 3 && session.items.isEmpty)
        guard case .failed = session.state else { preconditionFailure("Missing map region needs an explicit state") }
        session.clear()

        session.toggle(.bicycles, region: region)
        try await wait { provider.pending.count == 4 }
        provider.pending[3].resume(throwing: NSError(domain: MKErrorDomain,
            code: Int(MKError.Code.loadingThrottled.rawValue)))
        try await wait { if case .failed = session.state { return true }; return false }
        session.search(region: region)
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(provider.requests.count == 4, "Throttle cooldown prevents immediate retry storms")
        precondition(session.items.isEmpty && session.selectedItem == nil)

        let delayedProvider = ControlledPOIProvider()
        let delayed = OnlinePOISearchSession(provider: delayedProvider, debounceNanoseconds: 50_000_000)
        delayed.toggle(.food, region: region)
        delayed.clear()
        try await Task.sleep(nanoseconds: 70_000_000)
        precondition(delayedProvider.requests.isEmpty, "Cancel while debouncing without starting a network request")
        precondition(provider.cancellations >= 6)
        print("Online POI search: radius, deduplication, multi-selection, stale-response, dismissal, selection and throttle checks passed")
    }

    @MainActor
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("Timed out waiting for controlled search")
    }
}
