import Combine
import CoreLocation
import Foundation
import MapKit

/// The travel modes Create a Route offers.
enum RouteCreatorTravelMode: String, CaseIterable, Identifiable {
    case cycling
    case driving
    case walking

    var id: Self { self }

    var title: String {
        switch self {
        case .cycling: "Bike"
        case .driving: "Drive"
        case .walking: "Walk"
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .cycling: RouteTransportTypes.cycling
        case .driving: .automobile
        case .walking: .walking
        }
    }
}

/// What reverse geocoding found for a dropped pin.
struct RouteDroppedPinName: Equatable {
    let title: String
    let subtitle: String?
}

/// Create a Route on the main map. It owns the stops being edited, the travel
/// mode and the multi-stop planner; the main map and its bottom panel only
/// render it. Direct destination search never uses it.
@MainActor
final class RouteCreationSession: ObservableObject {
    typealias PlaceNamer = @MainActor (CLLocationCoordinate2D) async -> RouteDroppedPinName?

    static var stopLimitNotice: String {
        "A route can have up to \(MultiStopRouteDraft.maximumStops - MultiStopRouteDraft.minimumStops) stops between the start and destination."
    }

    @Published private(set) var isActive = false
    @Published private(set) var draft = MultiStopRouteDraft() {
        didSet { replan() }
    }
    @Published var travelMode = RouteCreatorTravelMode.cycling {
        didSet { replan() }
    }
    /// The stop whose place the panel is searching for.
    @Published private(set) var searchingStopID: UUID?
    /// Shown when another stop cannot be added.
    @Published private(set) var notice: String?

    let planner: MultiStopRoutePlanner
    private let namePlace: PlaceNamer
    private var plannerChanges: AnyCancellable?
    /// A stop made by Add Stop, removed again if its search ends without a pick.
    private var provisionalStopID: UUID?
    private var namingTasks: [UUID: Task<Void, Never>] = [:]
    private var savingPlan: MultiStopRoutePlan?

    init(
        planner: MultiStopRoutePlanner? = nil,
        namePlace: @escaping PlaceNamer = { _ in nil }
    ) {
        self.planner = planner ?? MultiStopRoutePlanner()
        self.namePlace = namePlace
        // The panel and the map read the plan through this session.
        plannerChanges = self.planner.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    var request: MultiStopRouteRequest? {
        draft.request(transportType: travelMode.transportType)
    }

    /// Save is offered only for the plan of the stops shown right now.
    var currentPlan: MultiStopRoutePlan? {
        guard let plan = planner.readyPlan, plan.request == request else { return nil }
        return plan
    }

    /// The failure of the plan for the stops shown right now.
    var currentFailure: MultiStopRoutePlanFailure? {
        guard planner.request == request else { return nil }
        return planner.failure
    }

    /// Starts a new route from the rider's position, or with an empty start.
    func begin(currentLocation: CLLocation?) {
        end()
        savingPlan = nil
        isActive = true
        draft = MultiStopRouteDraft(
            start: currentLocation.flatMap { MultiStopRoutePlace.currentLocation($0) }
        )
    }

    /// Discards the route being created. A save sheet already showing keeps
    /// its plan, so a save that completes afterwards still links a favorite.
    func end() {
        isActive = false
        cancelNaming()
        searchingStopID = nil
        provisionalStopID = nil
        notice = nil
        travelMode = .cycling
        draft = MultiStopRouteDraft()
        planner.cancel()
    }

    // MARK: - Search

    func search(forStopID id: UUID) {
        guard isActive, draft.stops.contains(where: { $0.id == id }) else { return }
        if provisionalStopID != id { dropProvisionalStop() }
        notice = nil
        searchingStopID = id
    }

    /// Add Stop: an empty stop before the destination, searched at once.
    func addStopAndSearch() {
        guard isActive else { return }
        dropProvisionalStop()
        var updated = draft
        guard let id = updated.addStop() else {
            notice = Self.stopLimitNotice
            return
        }
        notice = nil
        provisionalStopID = id
        searchingStopID = id
        draft = updated
    }

    func cancelSearch() {
        dropProvisionalStop()
        searchingStopID = nil
    }

    /// The place picked for the stop being searched.
    func choose(_ place: MultiStopRoutePlace) {
        guard let id = searchingStopID else { return }
        provisionalStopID = nil
        searchingStopID = nil
        setPlace(place, forStopID: id)
    }

    // MARK: - Map

    /// Touch and hold on the map. The place fills the stop being searched,
    /// otherwise the first stop still without a place, otherwise a new stop
    /// just before the destination. Returns that stop, or nil at the limit.
    @discardableResult
    func addDroppedPin(at coordinate: CLLocationCoordinate2D) -> UUID? {
        guard isActive,
              let place = MultiStopRoutePlace(
                  label: MultiStopRoutePlace.droppedPinLabel,
                  mapCoordinate: coordinate,
                  origin: .droppedPin
              ) else { return nil }
        var updated = draft
        let stopID: UUID
        if let id = searchingStopID {
            stopID = id
            provisionalStopID = nil
            searchingStopID = nil
        } else if let empty = updated.stops.first(where: { $0.place == nil }) {
            stopID = empty.id
        } else if let id = updated.addStop() {
            stopID = id
        } else {
            notice = Self.stopLimitNotice
            return nil
        }
        notice = nil
        namingTasks[stopID]?.cancel()
        updated.setPlace(place, forStopID: stopID)
        draft = updated
        name(place, forStopID: stopID)
        return stopID
    }

    /// Removes a stop, or clears it while the route has only two.
    func removeOrClear(stopID id: UUID) {
        guard draft.stops.contains(where: { $0.id == id }) else { return }
        namingTasks.removeValue(forKey: id)?.cancel()
        if provisionalStopID == id { provisionalStopID = nil }
        if searchingStopID == id { searchingStopID = nil }
        notice = nil
        if draft.canRemoveStop {
            draft.removeStop(id: id)
        } else {
            draft.setPlace(nil, forStopID: id)
        }
    }

    // MARK: - Order

    func moveStops(fromOffsets source: IndexSet, toOffset destination: Int) {
        notice = nil
        draft.moveStops(fromOffsets: source, toOffset: destination)
    }

    func moveStop(id: UUID, by offset: Int) {
        notice = nil
        draft.moveStop(id: id, by: offset)
    }

    func reverse() {
        notice = nil
        draft.reverse()
    }

    func retry() {
        planner.retry()
    }

    // MARK: - Save

    /// The immutable save draft of the plan shown right now.
    func beginSave() -> OfflineRouteSaveDraft? {
        guard let plan = currentPlan else { return nil }
        savingPlan = plan
        return plan.draft
    }

    /// After the shared save sheet stored the route. As before, a route ending
    /// at a favorite becomes that favorite's saved route. Ends the session.
    func finishSave(
        _ result: OfflineRouteSaveResult,
        destinationStore: SavedDestinationStore
    ) {
        if let plan = savingPlan,
           case .saved(let destination)? = plan.request.places.last?.origin,
           destinationStore.isFavorite(destination) {
            destinationStore.addFavorite(destination, savedRouteID: result.summary.id)
        }
        savingPlan = nil
        if isActive { end() }
    }

    // MARK: - Private

    private func setPlace(_ place: MultiStopRoutePlace, forStopID id: UUID) {
        namingTasks.removeValue(forKey: id)?.cancel()
        notice = nil
        draft.setPlace(place, forStopID: id)
    }

    private func replan() {
        planner.plan(isActive ? request : nil)
    }

    private func dropProvisionalStop() {
        guard let id = provisionalStopID else { return }
        provisionalStopID = nil
        if searchingStopID == id { searchingStopID = nil }
        guard let stop = draft.stops.first(where: { $0.id == id }), stop.place == nil,
              draft.canRemoveStop else { return }
        draft.removeStop(id: id)
    }

    /// Names a dropped pin once reverse geocoding answers, if the stop still
    /// holds that same pin. Only the label changes, so cached legs are reused.
    private func name(_ place: MultiStopRoutePlace, forStopID id: UUID) {
        let coordinate = place.clCoordinate
        namingTasks[id] = Task { [weak self, namePlace] in
            let name = await namePlace(coordinate)
            guard !Task.isCancelled, let self else { return }
            self.namingTasks[id] = nil
            guard let name,
                  self.draft.stops.first(where: { $0.id == id })?.place == place,
                  let named = MultiStopRoutePlace(
                      label: name.title,
                      subtitle: name.subtitle,
                      mapCoordinate: coordinate,
                      origin: .droppedPin
                  ) else { return }
            self.draft.setPlace(named, forStopID: id)
        }
    }

    private func cancelNaming() {
        namingTasks.values.forEach { $0.cancel() }
        namingTasks.removeAll()
    }
}
