import Combine
import CoreLocation
import MapKit

enum OnlinePOICategory: String, CaseIterable, Identifiable {
    case shops, food, toilets, fuel, bicycles

    var id: Self { self }

    var title: String {
        switch self {
        case .shops: return "Shops"
        case .food: return "Restaurants & Cafés"
        case .toilets: return "Public Toilets"
        case .fuel: return "Gas Stations"
        case .bicycles: return "Bicycle Shops & Repair"
        }
    }

    var symbol: String {
        switch self {
        case .shops: return "bag.fill"
        case .food: return "fork.knife"
        case .toilets: return "toilet.fill"
        case .fuel: return "fuelpump.fill"
        case .bicycles: return "bicycle"
        }
    }

    var mapKitCategories: [MKPointOfInterestCategory] {
        switch self {
        case .shops: return [.store, .foodMarket]
        case .food: return [.restaurant, .cafe]
        case .toilets: return [.restroom]
        case .fuel: return [.gasStation]
        case .bicycles: return [] // MapKit has no dedicated bicycle category.
        }
    }
}

@MainActor
protocol OnlinePOISearchProviding: AnyObject {
    func search(categories: Set<OnlinePOICategory>, center: CLLocationCoordinate2D,
                radius: CLLocationDistance) async throws -> [MKMapItem]
    func cancel()
}

/// Only retains MapKit responses for the current foreground search. This service
/// has no destination-store, route-library, backend, Watch or BLE dependency.
@MainActor
final class MapKitOnlinePOISearchProvider: OnlinePOISearchProviding {
    private var searches: [UUID: MKLocalSearch] = [:]

    func search(categories: Set<OnlinePOICategory>, center: CLLocationCoordinate2D,
                radius: CLLocationDistance) async throws -> [MKMapItem] {
        var items: [MKMapItem] = []
        let filters = OnlinePOICategory.allCases.filter { categories.contains($0) }
            .flatMap(\.mapKitCategories)
        if !filters.isEmpty {
            let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: filters)
            items += try await perform(MKLocalSearch(request: request))
        }
        if categories.contains(.bicycles) {
            // Text search is approximate, and deliberately doesn't restrict to
            // .store: standalone repair services may have another category.
            for query in [String(localized: "bicycle shop"), String(localized: "bicycle repair")] {
                try Task.checkCancellation()
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.resultTypes = .pointOfInterest
                request.region = MKCoordinateRegion(center: center,
                    latitudinalMeters: radius * 2, longitudinalMeters: radius * 2)
                if #available(iOS 18.0, macOS 15.0, *) {
                    request.regionPriority = .required
                }
                items += try await perform(MKLocalSearch(request: request))
            }
        }
        return items
    }

    func cancel() {
        let pending = Array(searches.values)
        searches.removeAll()
        pending.forEach { $0.cancel() }
    }

    private func perform(_ search: MKLocalSearch) async throws -> [MKMapItem] {
        try Task.checkCancellation()
        let id = UUID()
        searches[id] = search
        defer { searches.removeValue(forKey: id) }
        let response = try await search.start()
        try Task.checkCancellation()
        return response.mapItems
    }
}

/// Ephemeral iPhone UI state. Never convert these items into SavedDestination
/// or route endpoints: both can enter persistence and accessory relay paths.
@MainActor
final class OnlinePOISearchSession: ObservableObject {
    enum State: Equatable {
        case idle, loading, loaded, failed(String)
    }

    @Published private(set) var categories: Set<OnlinePOICategory> = []
    @Published private(set) var items: [MKMapItem] = []
    @Published private(set) var selectedItem: MKMapItem?
    @Published private(set) var state: State = .idle
    private(set) var center: CLLocationCoordinate2D?
    let radius: CLLocationDistance

    private let provider: any OnlinePOISearchProviding
    private let debounceNanoseconds: UInt64
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var retryAfter: Date?

    var isActive: Bool { !categories.isEmpty }

    init(provider: (any OnlinePOISearchProviding)? = nil,
         debounceNanoseconds: UInt64 = 300_000_000) {
        self.provider = provider ?? MapKitOnlinePOISearchProvider()
        self.debounceNanoseconds = debounceNanoseconds
        radius = min(1_000, MKLocalPointsOfInterestRequest.maxRadius)
    }

    func toggle(_ category: OnlinePOICategory, region: MKCoordinateRegion?) {
        if categories.contains(category) { categories.remove(category) }
        else { categories.insert(category) }
        if categories.isEmpty { clear() }
        else { search(region: region) }
    }

    func search(region: MKCoordinateRegion?) {
        invalidateRequest()
        items = []
        selectedItem = nil
        center = nil
        guard isActive else { state = .idle; return }
        guard let region, CLLocationCoordinate2DIsValid(region.center) else {
            state = .failed("Move the map to the area you want to search.")
            return
        }
        if let retryAfter, retryAfter > Date() {
            state = .failed("Search is temporarily busy. Try again shortly.")
            return
        }
        let requestGeneration = generation
        let requestCategories = categories
        let requestCenter = region.center
        center = requestCenter
        state = .loading
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
                try Task.checkCancellation()
                let response = try await provider.search(categories: requestCategories,
                    center: requestCenter, radius: radius)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                items = Self.nearbyUniqueItems(response, center: requestCenter, radius: radius)
                state = .loaded
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                if (error as NSError).domain == MKErrorDomain,
                   (error as NSError).code == MKError.Code.loadingThrottled.rawValue {
                    retryAfter = Date().addingTimeInterval(5)
                    state = .failed("Search is temporarily busy. Try again shortly.")
                } else {
                    state = .failed("Nearby search is unavailable. Check your internet connection and try again.")
                }
            }
        }
    }

    func select(_ item: MKMapItem) {
        guard selectedItem !== item, items.contains(where: { $0 === item }) else { return }
        selectedItem = item
    }

    func clear() {
        invalidateRequest()
        categories = []
        items = []
        selectedItem = nil
        center = nil
        state = .idle
    }

    func distance(to item: MKMapItem) -> CLLocationDistance? {
        guard let center else { return nil }
        return CLLocation(latitude: center.latitude, longitude: center.longitude)
            .distance(from: CLLocation(latitude: item.placemark.coordinate.latitude,
                                      longitude: item.placemark.coordinate.longitude))
    }

    private func invalidateRequest() {
        generation &+= 1
        task?.cancel()
        task = nil
        provider.cancel()
    }

    static func nearbyUniqueItems(_ items: [MKMapItem], center: CLLocationCoordinate2D,
                                  radius: CLLocationDistance) -> [MKMapItem] {
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        var unique: [MKMapItem] = []
        for item in items {
            let coordinate = item.placemark.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            guard origin.distance(from: location) <= radius else { continue }
            // Older supported OS versions have no Place IDs. This conservative,
            // session-only fallback removes overlapping shop/text-search hits.
            guard !unique.contains(where: {
                $0.name == item.name &&
                    CLLocation(latitude: $0.placemark.coordinate.latitude,
                               longitude: $0.placemark.coordinate.longitude)
                        .distance(from: location) < 10
            }) else { continue }
            unique.append(item)
        }
        return unique.sorted {
            origin.distance(from: CLLocation(latitude: $0.placemark.coordinate.latitude,
                longitude: $0.placemark.coordinate.longitude)) <
            origin.distance(from: CLLocation(latitude: $1.placemark.coordinate.latitude,
                longitude: $1.placemark.coordinate.longitude))
        }
    }
}
