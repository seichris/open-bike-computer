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

    var searchQueries: [String] {
        switch self {
        case .shops: return [String(localized: "store")]
        case .food: return [String(localized: "restaurant"), String(localized: "cafe")]
        case .toilets: return [String(localized: "public toilet")]
        case .fuel: return [String(localized: "gas station")]
        case .bicycles: return [String(localized: "bike shop"), String(localized: "bicycle repair")]
        }
    }
}

struct OnlinePOISearchResponse {
    let items: [MKMapItem]
    var usedCategoryTextFallback = false
}

@MainActor
protocol OnlinePOISearchProviding: AnyObject {
    func search(categories: Set<OnlinePOICategory>, center: CLLocationCoordinate2D,
                radius: CLLocationDistance) async throws -> OnlinePOISearchResponse
    func cancel()
}

/// Only retains MapKit responses for the current foreground search. This service
/// has no destination-store, route-library, backend, Watch or BLE dependency.
@MainActor
final class MapKitOnlinePOISearchProvider: OnlinePOISearchProviding {
    private var searches: [UUID: MKLocalSearch] = [:]
    private let execute: (@MainActor (MKLocalSearch) async throws -> [MKMapItem])?

    init(execute: (@MainActor (MKLocalSearch) async throws -> [MKMapItem])? = nil) {
        self.execute = execute
    }

    func search(categories: Set<OnlinePOICategory>, center: CLLocationCoordinate2D,
                radius: CLLocationDistance) async throws -> OnlinePOISearchResponse {
        var items: [MKMapItem] = []
        var usedCategoryTextFallback = false
        var queries: [String] = []
        let filters = OnlinePOICategory.allCases.filter { categories.contains($0) }
            .flatMap(\.mapKitCategories)
        if !filters.isEmpty {
            let request = MKLocalPointsOfInterestRequest(center: center, radius: radius)
            request.pointOfInterestFilter = MKPointOfInterestFilter(including: filters)
            do {
                items += try await perform(MKLocalSearch(request: request))
            } catch {
                try Task.checkCancellation()
                // Observed with the structured POI endpoint in Shanghai, where
                // ordinary Apple local text search still works. Never fan out
                // after a network/server/throttling error or retry in a loop.
                let failure = error as NSError
                guard failure.domain == MKErrorDomain,
                      failure.code == Int(MKError.Code.directionsNotFound.rawValue) else { throw error }
                usedCategoryTextFallback = true
                queries += OnlinePOICategory.allCases
                    .filter { categories.contains($0) && $0 != .bicycles }
                    .flatMap(\.searchQueries)
            }
        }
        if categories.contains(.bicycles) {
            // Text search is approximate, and deliberately doesn't restrict to
            // .store: standalone repair services may have another category.
            queries += OnlinePOICategory.bicycles.searchQueries
        }
        // At most seven sequential text queries for an explicit all-category
        // selection, after one structured request; no grid crawling/prefetch.
        for query in queries {
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
        return OnlinePOISearchResponse(items: items, usedCategoryTextFallback: usedCategoryTextFallback)
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
        do {
            let items: [MKMapItem]
            if let execute { items = try await execute(search) }
            else { items = try await search.start().mapItems }
            try Task.checkCancellation()
            return items
        } catch {
            try Task.checkCancellation()
            let failure = error as NSError
            if failure.domain == MKErrorDomain,
               failure.code == Int(MKError.Code.placemarkNotFound.rawValue) { return [] }
            throw error
        }
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
    @Published private(set) var usedCategoryTextFallback = false
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
        usedCategoryTextFallback = false
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
                items = Self.nearbyUniqueItems(response.items, center: requestCenter, radius: radius)
                usedCategoryTextFallback = response.usedCategoryTextFallback
                state = .loaded
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
#if DEBUG
                // Codes only: never log queries, locations, POI payloads or
                // error descriptions, which can contain provider data.
                let failure = error as NSError
                NSLog("Online POI search failure domain=%@ code=%ld", failure.domain, failure.code)
#endif
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

    func select(_ item: MKMapItem?) {
        guard selectedItem !== item else { return }
        if let item, !items.contains(where: { $0 === item }) { return }
        selectedItem = item
    }

    func clear() {
        invalidateRequest()
        categories = []
        items = []
        selectedItem = nil
        center = nil
        usedCategoryTextFallback = false
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
