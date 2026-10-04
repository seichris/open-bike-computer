import Combine
import CoreLocation
import HealthKit
import SwiftUI

@MainActor
final class SocialActivityExport: ObservableObject {
    @Published var workouts: [HKWorkout] = []
    @Published var locations: [CLLocation] = []
    @Published var selected: HKWorkout?
    @Published var localPreview: SocialContentBody?
    @Published var error: String?
    private let health = HKHealthStore()

    func load() async throws {
        let types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        try await health.requestAuthorization(toShare: [], read: types)
        let predicate = HKQuery.predicateForWorkouts(with: .cycling)
        let values: [HKWorkout] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                limit: 100, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples as? [HKWorkout] ?? []) }
            }
            health.execute(query)
        }
        let bundle = Bundle.main.bundleIdentifier ?? ""
        workouts = values.filter {
            [$0.sourceRevision.source.bundleIdentifier].contains(where: { $0 == bundle || $0 == bundle + ".watchkitapp" })
        }
    }

    func select(_ workout: HKWorkout, zones: [SocialZone]) async throws {
        let health = self.health
        locations = []; selected = nil; localPreview = nil
        let routeSamples: [HKWorkoutRoute] = try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                predicate: HKQuery.predicateForObjects(from: workout), limit: 50, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples as? [HKWorkoutRoute] ?? []) }
            }
            health.execute(query)
        }
        var all: [CLLocation] = []
        for route in routeSamples {
            let batch: [CLLocation] = try await withCheckedThrowingContinuation { continuation in
                var points: [CLLocation] = []
                var completed = false
                let query = HKWorkoutRouteQuery(route: route) { query, locations, done, error in
                    guard !completed else { return }
                    if let error { completed = true; continuation.resume(throwing: error); return }
                    points.append(contentsOf: locations ?? [])
                    if points.count > 20000 {
                        completed = true
                        health.stop(query)
                        continuation.resume(throwing: SocialFailure.server("ride_track_too_large"))
                    } else if done { completed = true; continuation.resume(returning: points) }
                }
                health.execute(query)
            }
            guard all.count + batch.count <= 20000 else { throw SocialFailure.server("ride_track_too_large") }
            all.append(contentsOf: batch)
        }
        guard all.count >= 2 && all.count <= 20000 else { throw SocialFailure.server("ride_route_unavailable") }
        locations = all.sorted { $0.timestamp < $1.timestamp }
        localPreview = try await Self.clip(locations, zones: zones)
        selected = workout
    }

    // Preview on the phone before consent to upload. The server independently
    // processes the original selected track and returns the publication preview.
    private static func clip(_ locations: [CLLocation], zones: [SocialZone]) async throws -> SocialContentBody {
        guard let first = locations.first, let last = locations.last else { throw SocialFailure.invalidResponse }
        let zones = zones + [SocialZone(latitude: first.coordinate.latitude, longitude: first.coordinate.longitude, radius: 200),
                             SocialZone(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude, radius: 200)]
        let centers = zones.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        var segments: [[SocialPoint]] = []; var current: [SocialPoint] = []; var total = 0
        func vector(_ p: CLLocationCoordinate2D) -> [Double] {
            let lat = p.latitude * .pi / 180, lon = p.longitude * .pi / 180
            return [cos(lat)*cos(lon), cos(lat)*sin(lon), sin(lat)]
        }
        for (a,b) in zip(locations, locations.dropFirst()) {
            let count = max(1, Int(ceil(a.distance(from: b)/25)))
            total += count
            guard total <= 100000 else { throw SocialFailure.server("ride_track_too_large") }
            let x = vector(a.coordinate), y = vector(b.coordinate)
            let angle = acos(max(-1,min(1,zip(x,y).reduce(0) { $0+$1.0*$1.1 })))
            guard angle < .pi-0.00001 else { throw SocialFailure.server("invalid_track") }
            for i in 0..<count {
                let f = Double(i)/Double(count)
                let l = angle < 1e-10 ? 1 : sin((1-f)*angle)/sin(angle)
                let r = angle < 1e-10 ? 0 : sin(f*angle)/sin(angle)
                let v = zip(x,y).map { l*$0.0+r*$0.1 }
                let p = SocialPoint(latitude: atan2(v[2],hypot(v[0],v[1]))*180 / .pi,
                                    longitude: atan2(v[1],v[0])*180 / .pi)
                let location = CLLocation(latitude: p.latitude, longitude: p.longitude)
                let hidden = zip(centers,zones).contains { location.distance(from: $0.0) <= $0.1.radius+26 }
                if hidden {
                    if current.count > 1 { segments.append(current) }; current = []
                } else { current.append(p) }
                if i % 256 == 0 { await Task.yield(); try Task.checkCancellation() }
            }
        }
        if current.count > 1 { segments.append(current) }
        let meters = segments.reduce(0.0) { result, segment in
            result + zip(segment,segment.dropFirst()).reduce(0.0) { value, pair in
                value + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                    .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
            }
        }
        return SocialContentBody(archive: nil, sha256: nil, segments: segments, distanceMeters: meters,
            movingSeconds: nil, elapsedSeconds: nil, averageSpeed: nil, needsReprocessing: nil)
    }

    var movingSeconds: Double {
        zip(locations, locations.dropFirst()).reduce(0) { total, pair in
            let duration = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            guard duration > 0 && duration <= 30, pair.0.distance(from: pair.1) / duration > 0.5 else { return total }
            return total + duration
        }
    }
}

struct SocialActivityPublisher: View {
    @ObservedObject var store: SocialCoordinator
    @StateObject private var export = SocialActivityExport()
    @State private var title = "My ride"
    @State private var visibility = "private"
    @State private var consent = false
    @State private var preview: SocialContentBody?
    @State private var published: SocialContent?
    @State private var busy = false

    var body: some View {
        List {
            Section {
                Text("Select one Bicino ride. Preparing a private preview uploads its route and basic times for privacy processing. Heart rate, calories, power, cadence, and other Health data are excluded.")
                Button("Choose from my Bicino workouts") { run { try await export.load() } }
                ForEach(export.workouts, id: \.uuid) { workout in
                    Button(workout.startDate.formatted(date: .abbreviated, time: .shortened)) {
                        run { try await export.select(workout, zones: store.profile?.privacy?.zones ?? []); preview = nil; published = nil }
                    }
                }
            }
            if let selected = export.selected {
                Section {
                    TextField("Ride title", text: $title)
                    Text(selected.startDate, style: .date)
                    if let local = export.localPreview {
                        SocialTrackPreview(content: local).frame(height: 220)
                        Text("Local privacy preview. The server checks clipping again before publication.").font(.caption)
                    }
                    Toggle("I agree to upload this route and its basic times", isOn: $consent)
                    Button("Prepare private preview") { run {
                        let points = export.locations.map { ["latitude": $0.coordinate.latitude, "longitude": $0.coordinate.longitude] }
                        let value = try await store.client.json("activities", method: "POST", body: [
                            "title": title, "visibility": "private", "sourceID": selected.uuid.uuidString,
                            "points": points, "movingSeconds": export.movingSeconds,
                            "elapsedSeconds": selected.endDate.timeIntervalSince(selected.startDate), "uploadConsent": true])
                        let item = try JSONDecoder().decode(SocialContent.self, from: JSONSerialization.data(withJSONObject: value))
                        published = item; preview = item.body
                    } }.disabled(!consent)
                }
            }
            if let preview, let published {
                Section("Only this processed map will be shared") {
                    SocialTrackPreview(content: preview).frame(height: 260)
                    Text("Visible distance: \(Int(preview.distanceMeters ?? 0)) m")
                    Text("Full-ride moving time: \(Int(export.movingSeconds / 60)) min")
                    Text("Start/finish areas and your private zones have been removed. Review the visible track before choosing who can see it.").font(.caption)
                    SocialVisibilityPicker(selection: $visibility)
                    Button("Save sharing choice") { run {
                        let value = try await store.client.json("activities/\(published.id)", method: "PATCH", body: [
                            "title": title, "visibility": visibility, "revision": published.revision])
                        self.published = try JSONDecoder().decode(SocialContent.self, from: JSONSerialization.data(withJSONObject: value))
                        try await store.refresh()
                    } }
                    Button("Delete uploaded preview", role: .destructive) { run {
                        try await store.mutate("activities/\(published.id)", method: "DELETE")
                        self.published = nil; self.preview = nil
                    } }
                }
            }
            if let error = store.error { Text(error).foregroundStyle(.red) }
        }.navigationTitle("Share completed ride").disabled(busy)
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { defer { busy = false }; do { try await work() } catch { store.error = error.localizedDescription } }
    }
}
