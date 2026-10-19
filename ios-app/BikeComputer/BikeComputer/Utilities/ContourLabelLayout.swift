import CoreGraphics
import Foundation

/// Coverage reuse is independent of marker motion. Keep queries bounded while
/// allowing follow-mode GPS updates to lay out cached anchors without SQLite.
nonisolated struct ContourLabelCoverage {
    private(set) var rect: CGRect?
    mutating func queryRect(for visible: CGRect) -> CGRect? {
        if let rect, rect.contains(visible),
           rect.width <= visible.width * 2, rect.height <= visible.height * 2 { return nil }
        let expanded = visible.insetBy(dx: -visible.width / 4, dy: -visible.height / 4)
        rect = expanded
        return expanded
    }
}

/// Screen-sized route occupancy has constant storage even for very long GPX
/// files. Clip first, then walk the crossed cells; a diagonal never reserves
/// its entire bounding rectangle. Padding is applied to label queries.
nonisolated struct ContourRouteOccupancy {
    private let bounds: CGRect
    private let side: CGFloat = 12
    private let columns: Int
    private let rows: Int
    private var occupied = Set<Int>()
    init(bounds: CGRect) {
        self.bounds = bounds
        columns = max(1, Int(ceil(bounds.width / 12)))
        rows = max(1, Int(ceil(bounds.height / 12)))
    }
    mutating func add(_ a: CGPoint, _ b: CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        var low: CGFloat = 0, high: CGFloat = 1
        for (p, q) in [(-dx, a.x - bounds.minX), (dx, bounds.maxX - a.x),
                       (-dy, a.y - bounds.minY), (dy, bounds.maxY - a.y)] {
            if p == 0 { if q < 0 { return }; continue }
            let t = q / p
            if p < 0 { low = max(low, t) } else { high = min(high, t) }
            if low > high { return }
        }
        let start = CGPoint(x: (a.x + low * dx - bounds.minX) / side,
                            y: (a.y + low * dy - bounds.minY) / side)
        let end = CGPoint(x: (a.x + high * dx - bounds.minX) / side,
                          y: (a.y + high * dy - bounds.minY) / side)
        var x = max(0, min(columns - 1, Int(floor(start.x))))
        var y = max(0, min(rows - 1, Int(floor(start.y))))
        let endX = max(0, min(columns - 1, Int(floor(end.x))))
        let endY = max(0, min(rows - 1, Int(floor(end.y))))
        let vx = end.x - start.x, vy = end.y - start.y
        let stepX = vx < 0 ? -1 : 1, stepY = vy < 0 ? -1 : 1
        let deltaX = vx == 0 ? CGFloat.infinity : abs(1 / vx)
        let deltaY = vy == 0 ? CGFloat.infinity : abs(1 / vy)
        var nextX = vx == 0 ? CGFloat.infinity : (vx > 0 ? CGFloat(x + 1) - start.x : start.x - CGFloat(x)) * deltaX
        var nextY = vy == 0 ? CGFloat.infinity : (vy > 0 ? CGFloat(y + 1) - start.y : start.y - CGFloat(y)) * deltaY
        for _ in 0..<(columns + rows + 2) {
            occupied.insert(y * columns + x)
            if x == endX && y == endY { break }
            if nextX < nextY { x += stepX; nextX += deltaX }
            else { y += stepY; nextY += deltaY }
            if x < 0 || x >= columns || y < 0 || y >= rows { break }
        }
    }
    func intersects(_ box: CGRect, padding: CGFloat = 12) -> Bool {
        let box = box.insetBy(dx: -padding, dy: -padding).intersection(bounds)
        guard !box.isNull else { return false }
        let left = max(0, min(columns - 1, Int(floor((box.minX - bounds.minX) / side))))
        let right = max(left, min(columns - 1, Int(floor((box.maxX - bounds.minX) / side))))
        let top = max(0, min(rows - 1, Int(floor((box.minY - bounds.minY) / side))))
        let bottom = max(top, min(rows - 1, Int(floor((box.maxY - bounds.minY) / side))))
        for y in top...bottom {
            for x in left...right where occupied.contains(y * columns + x) { return true }
        }
        return false
    }
}
