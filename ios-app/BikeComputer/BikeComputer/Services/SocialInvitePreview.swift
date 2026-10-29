import MapKit
import UIKit

/// An actual map snapshot. Apple's attribution remains visible above the footer.
@MainActor
enum SocialInvitePreview {
    static func render(ride: SocialGroupRide) async throws -> Data {
        guard let raw = ride.route.archive,
              let archive = try? NavigationRouteArchiveV1.decode(Data(raw.utf8), purpose: .offlineNavigation) else {
            throw SocialFailure.invalidResponse
        }
        let coordinates = archive.route.points.map {
            CoordinateConverter.wgs84ToGCJ02(coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
        }
        guard coordinates.count > 1 else { throw SocialFailure.invalidResponse }
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        var rect = line.boundingMapRect
        let padding = max(rect.width, rect.height) * 0.18 + 200
        rect = rect.insetBy(dx: -padding, dy: -padding)
        let options = MKMapSnapshotter.Options()
        options.mapRect = rect
        options.size = CGSize(width: 1200, height: 480)
        options.scale = 1
        options.traitCollection = UITraitCollection(userInterfaceStyle: .light)
        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot = try await withThrowingTaskGroup(of: MKMapSnapshotter.Snapshot.self) { tasks in
            tasks.addTask { try await snapshotter.start() }
            tasks.addTask {
                try await Task.sleep(nanoseconds: 20_000_000_000)
                snapshotter.cancel()
                throw URLError(.timedOut)
            }
            defer { tasks.cancelAll() }
            return try await tasks.next()!
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 630), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 630))
            snapshot.image.draw(at: .zero)
            context.cgContext.saveGState()
            // Leave room for the MapKit logo and attribution at the map's bottom.
            context.cgContext.clip(to: CGRect(x: 0, y: 0, width: 1200, height: 445))
            let path = UIBezierPath()
            for (index, coordinate) in coordinates.enumerated() {
                let point = snapshot.point(for: coordinate)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.lineWidth = 7; path.lineJoinStyle = .round; path.lineCapStyle = .round
            UIColor.systemBlue.setStroke(); path.stroke()
            context.cgContext.restoreGState()
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (ride.title as NSString).draw(in: CGRect(x: 36, y: 497, width: 1128, height: 45), withAttributes: [
                .font: UIFont.systemFont(ofSize: 34, weight: .bold), .foregroundColor: UIColor.black, .paragraphStyle: paragraph])
            let km = String(format: "%.1f km", (ride.route.distanceMeters ?? archive.route.distanceMeters) / 1000)
            ("\(km) · Join the group ride" as NSString).draw(in: CGRect(x: 36, y: 552, width: 1128, height: 45), withAttributes: [
                .font: UIFont.systemFont(ofSize: 29, weight: .semibold), .foregroundColor: UIColor.systemBlue])
            ("Map: Apple Maps" as NSString).draw(at: CGPoint(x: 1035, y: 605), withAttributes: [
                .font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.darkGray])
        }
        guard let data = image.pngData() else { throw SocialFailure.invalidResponse }
        return data
    }
}
