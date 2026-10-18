import CoreLocation
import MapKit
import UIKit

final class SocialRiderAnnotation: NSObject, MKAnnotation {
    let id: String
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var rider: SocialRider
    init(_ rider: SocialRider) {
        id = rider.id; self.rider = rider; title = rider.profile.displayName
        coordinate = CoordinateConverter.wgs84ToGCJ02(coordinate: rider.coordinate)
    }
}

@MainActor
final class SocialRiderBadge: UIView {
    let picture = UIImageView()
    let initials = UILabel()
    let distance = UILabel()
    let cluster = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        picture.frame = CGRect(x: 4, y: 0, width: 40, height: 40)
        picture.layer.cornerRadius = 20; picture.clipsToBounds = true
        picture.layer.borderWidth = 2; picture.layer.borderColor = UIColor.white.cgColor
        picture.backgroundColor = .systemBlue; picture.contentMode = .scaleAspectFill
        initials.frame = picture.frame; initials.textAlignment = .center; initials.textColor = .white
        initials.font = .boldSystemFont(ofSize: 15)
        distance.frame = CGRect(x: -12, y: 40, width: 72, height: 20)
        distance.textAlignment = .center; distance.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        distance.textColor = .label; distance.backgroundColor = .systemBackground
        distance.layer.cornerRadius = 5; distance.clipsToBounds = true
        cluster.frame = CGRect(x: 29, y: -2, width: 27, height: 20)
        cluster.backgroundColor = .systemBackground; cluster.textColor = .label
        cluster.font = .boldSystemFont(ofSize: 12); cluster.textAlignment = .center
        cluster.layer.cornerRadius = 8; cluster.clipsToBounds = true; cluster.isHidden = true
        addSubview(cluster)
        addSubview(picture); addSubview(initials); addSubview(distance); bringSubviewToFront(cluster)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func update(_ rider: SocialRider, photo: UIImage?, meters: Double?, stale: Bool) {
        picture.image = photo; initials.text = photo == nil ? rider.profile.initials : nil
        distance.isHidden = meters == nil
        if let meters {
            distance.text = (stale ? "~" : "") + (meters < 1000 ? "\(Int(meters.rounded())) m" : String(format: "%.1f km", meters/1000))
        }
        alpha = stale ? 0.45 : 1
        accessibilityLabel = "\(rider.profile.displayName), \(distance.text ?? ""), \(stale ? "stale location" : "live location")"
    }
}

@MainActor
final class SocialMapLayer {
    private weak var map: MKMapView?
    private var riders: [String: SocialRider] = [:]
    private var photos: [String: UIImage] = [:]
    private var annotations: [String: SocialRiderAnnotation] = [:]
    private var edges: [String: SocialRiderBadge] = [:]
    private var ownLocation: CLLocation?
    private var timer: Timer?

    func update(on map: MKMapView, riders: [SocialRider], photos: [String: UIImage], location: CLLocation?) {
        self.map = map; self.photos = photos; ownLocation = location
        self.riders = Dictionary(riders.prefix(25).map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                Task { @MainActor in
                    guard let self, self.map != nil else { timer.invalidate(); return }
                    self.layout()
                }
            }
        }
        layout()
    }

    func annotationView(_ annotation: SocialRiderAnnotation, map: MKMapView) -> MKAnnotationView {
        let view = map.dequeueReusableAnnotationView(withIdentifier: "social-rider")
            ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "social-rider")
        view.annotation = annotation; view.frame.size = CGSize(width: 48, height: 60)
        view.centerOffset = CGPoint(x: 0, y: -10); view.canShowCallout = true
        let badge = (view.subviews.first { $0 is SocialRiderBadge } as? SocialRiderBadge)
            ?? SocialRiderBadge(frame: view.bounds)
        if badge.superview == nil { view.addSubview(badge) }
        badge.update(annotation.rider, photo: annotation.rider.profile.avatarID.flatMap { photos[$0] },
                     meters: nil, stale: annotation.rider.age(at: Date()) >= 15)
        let detail = UILabel()
        detail.numberOfLines = 0
        let speed = annotation.rider.speed.map { String(format: " · %.1f km/h", $0*3.6) } ?? ""
        detail.text = "Updated \(Int(annotation.rider.age(at: Date()))) s ago\(speed)"
        view.detailCalloutAccessoryView = detail
        view.accessibilityLabel = badge.accessibilityLabel
        return view
    }

    func layout() {
        guard let map else { return }
        let now = Date()
        let visible = riders.filter { $0.value.age(at: now) < 60 }
        for id in Array(annotations.keys) where visible[id] == nil {
            if let old = annotations.removeValue(forKey: id) { map.removeAnnotation(old) }
            edges.removeValue(forKey: id)?.removeFromSuperview()
        }
        var occupied: [(CGRect, String)] = []
        for badge in edges.values { badge.cluster.isHidden = true; badge.cluster.text = nil }
        for (id, rider) in visible.sorted(by: {
            guard let ownLocation else { return $0.key < $1.key }
            let a = ownLocation.distance(from: CLLocation(latitude: $0.value.latitude, longitude: $0.value.longitude))
            let b = ownLocation.distance(from: CLLocation(latitude: $1.value.latitude, longitude: $1.value.longitude))
            return a == b ? $0.key < $1.key : a < b
        }) {
            let annotation: SocialRiderAnnotation
            if let old = annotations[id] { annotation = old; old.rider = rider; old.coordinate = CoordinateConverter.wgs84ToGCJ02(coordinate: rider.coordinate) }
            else { annotation = SocialRiderAnnotation(rider); annotations[id] = annotation; map.addAnnotation(annotation) }
            let point = map.convert(annotation.coordinate, toPointTo: map)
            let onMap = map.bounds.insetBy(dx: 35, dy: 45).contains(point)
            map.view(for: annotation)?.isHidden = !onMap
            if onMap {
                edges.removeValue(forKey: id)?.removeFromSuperview()
                if let view = map.view(for: annotation), let badge = view.subviews.first(where: { $0 is SocialRiderBadge }) as? SocialRiderBadge {
                    badge.update(rider, photo: rider.profile.avatarID.flatMap { photos[$0] }, meters: nil, stale: rider.age(at: now) >= 15)
                }
                continue
            }
            guard let ownLocation, abs(ownLocation.timestamp.timeIntervalSinceNow) < 30,
                  ownLocation.horizontalAccuracy >= 0, ownLocation.horizontalAccuracy <= 100 else {
                edges.removeValue(forKey: id)?.removeFromSuperview(); continue
            }
            let target = CLLocation(latitude: rider.latitude, longitude: rider.longitude)
            let meters = ownLocation.distance(from: target)
            guard meters >= 3 else { edges.removeValue(forKey: id)?.removeFromSuperview(); continue }
            guard let center = SocialMapGeometry.edgeCenter(projected: point, bounds: map.bounds) else { continue }
            var origin = CGPoint(x: center.x-24, y: center.y-30)
            // Preserve bearing within a small arc; overlapping extras remain
            // available through the rider list instead of inventing a direction.
            let rect = CGRect(origin: origin, size: CGSize(width: 48, height: 60))
            if let overlap = occupied.first(where: { $0.0.intersects(rect) }), let retained = edges[overlap.1] {
                let previous = Int(retained.cluster.text?.dropFirst() ?? "0") ?? 0
                retained.cluster.text = "+\(previous + 1)"; retained.cluster.isHidden = false
                edges.removeValue(forKey: id)?.removeFromSuperview(); continue
            }
            occupied.append((rect,id))
            origin.x = origin.x.rounded(); origin.y = origin.y.rounded()
            let badge = edges[id] ?? SocialRiderBadge(frame: CGRect(origin: origin, size: rect.size))
            badge.frame.origin = origin
            badge.update(rider, photo: rider.profile.avatarID.flatMap { photos[$0] }, meters: meters, stale: rider.age(at: now) >= 15)
            if badge.superview == nil { map.addSubview(badge) }
            edges[id] = badge
        }
    }

    static func bearing(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> Double {
        let p = a.latitude * .pi/180, q = b.latitude * .pi/180, d = (b.longitude-a.longitude) * .pi/180
        return atan2(sin(d)*cos(q), cos(p)*sin(q)-sin(p)*cos(q)*cos(d)) * 180 / .pi
    }
}
