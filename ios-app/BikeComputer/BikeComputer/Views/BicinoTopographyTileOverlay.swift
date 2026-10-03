import Foundation
import MapKit
import SceneKit
import SwiftUI
import UIKit

/// Local transparent contours only. The signed companion stays in WGS-84; only
/// the MapKit presentation is remapped for wholly mainland-China selections.
nonisolated final class BicinoTopographyTileOverlay: MKTileOverlay, @unchecked Sendable {
  let receipt: TopographyCompanionReceipt
  private let store: TopographyCompanionStore
  private let mapBounds: MKMapRect
  let alignsChina: Bool
  let hasTerrainFeatures: Bool
  private let taskLock = NSLock()
  private var tileTasks: [UUID: Task<Void, Never>] = [:]
  private var memoryWarningObserver: NSObjectProtocol?

  private init(
    store: TopographyCompanionStore,
    metadata: TopographyCompanionMetadata,
    alignsChina: Bool
  ) {
    self.store = store
    self.receipt = store.receipt
    self.alignsChina = alignsChina
    self.hasTerrainFeatures = metadata.schemaVersion == 2
    let bounds = metadata.boundsE7.map { Double($0) / 10_000_000 }
    let northwestCoordinate = CLLocationCoordinate2D(latitude: bounds[3], longitude: bounds[0])
    let southeastCoordinate = CLLocationCoordinate2D(latitude: bounds[1], longitude: bounds[2])
    let northwest = MKMapPoint(
      alignsChina
        ? CoordinateConverter.wgs84ToGCJ02(coordinate: northwestCoordinate)
        : northwestCoordinate)
    let southeast = MKMapPoint(
      alignsChina
        ? CoordinateConverter.wgs84ToGCJ02(coordinate: southeastCoordinate)
        : southeastCoordinate)
    mapBounds = MKMapRect(
      x: northwest.x, y: northwest.y, width: southeast.x - northwest.x,
      height: southeast.y - northwest.y)
    super.init(urlTemplate: nil)
    canReplaceMapContent = false
    tileSize = CGSize(width: 256, height: 256)
    minimumZ = metadata.minimumZoom
    maximumZ = metadata.maximumZoom
    isGeometryFlipped = false
    memoryWarningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.purgeDecodedTiles()
    }
  }

  deinit {
    if let memoryWarningObserver {
      NotificationCenter.default.removeObserver(memoryWarningObserver)
    }
    cancelPendingLoads()
  }

  static func open(url: URL, receipt: TopographyCompanionReceipt) async throws
    -> BicinoTopographyTileOverlay
  {
    let store = TopographyCompanionStore(url: url, receipt: receipt)
    let metadata = try await store.validate()
    try Task.checkCancellation()
    let bounds = metadata.boundsE7.map { Double($0) / 10_000_000 }
    let corners = [
      (bounds[1], bounds[0]), (bounds[1], bounds[2]),
      (bounds[3], bounds[0]), (bounds[3], bounds[2]),
    ]
    let chinaCorners = corners.filter {
      CoordinateConverter.isInChina(lat: $0.0, lon: $0.1)
    }.count
    guard chinaCorners == 0 || chinaCorners == corners.count else {
      throw TopographyMapKitTileWarp.WarpError.extent
    }
    return BicinoTopographyTileOverlay(
      store: store, metadata: metadata, alignsChina: chinaCorners == corners.count
    )
  }

  func coordinate(worldX: Double, worldY: Double) -> CLLocationCoordinate2D {
    let coordinate = CLLocationCoordinate2D(
      latitude: atan(sinh(worldY / 6_378_137)) * 180 / .pi,
      longitude: worldX / 6_378_137 * 180 / .pi)
    return alignsChina ? CoordinateConverter.wgs84ToGCJ02(coordinate: coordinate) : coordinate
  }

  func world(_ coordinate: CLLocationCoordinate2D) -> (Double, Double) {
    let point =
      alignsChina
      ? CoordinateConverter.gcj02ToWGS84(lat: coordinate.latitude, lon: coordinate.longitude)
      : (lat: coordinate.latitude, lon: coordinate.longitude)
    let latitude = max(-85.05112878, min(85.05112878, point.lat)) * .pi / 180
    return (point.lon * .pi / 180 * 6_378_137, log(tan(.pi / 4 + latitude / 2)) * 6_378_137)
  }

  func labelAnchors(in rect: MKMapRect) async throws -> [ContourLabelAnchor] {
    let nw = world(MKMapPoint(x: rect.minX, y: rect.minY).coordinate)
    let se = world(MKMapPoint(x: rect.maxX, y: rect.maxY).coordinate)
    return try await store.labels(
      west: Int(nw.0) - 256, south: Int(se.1) - 256, east: Int(se.0) + 256, north: Int(nw.1) + 256)
  }

  func terrain(near coordinate: CLLocationCoordinate2D) async throws -> [TerrainGrid] {
    let point = world(coordinate)
    return try await store.terrain(x: Int(floor(point.0 / 4096)), y: Int(floor(point.1 / 4096)))
  }

  override var boundingMapRect: MKMapRect { mapBounds }
  override var coordinate: CLLocationCoordinate2D {
    MKMapPoint(x: mapBounds.midX, y: mapBounds.midY).coordinate
  }

  override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
    // Objective-C MapKit predates @Sendable on this callback. Its contract
    // permits asynchronous completion. One task owns exactly one reply.
    let reply = TileReply(result)
    let store = store
    let x = path.x
    let y = path.y
    let z = path.z
    let scale = path.contentScaleFactor > 1 ? 2 : 1
    let alignsChina = alignsChina
    let taskID = UUID()
    taskLock.lock()
    tileTasks[taskID] = Task { [weak self] in
      defer { self?.finishTask(taskID) }
      do {
        let data: Data?
        if alignsChina {
          data = try await TopographyMapKitTileWarp.tile(
            z: z, x: x, y: y, scale: scale
          ) { z, x, y, scale in
            try await store.tile(z: z, x: x, y: y, scale: scale)
          }
        } else {
          data = try await store.tile(z: z, x: x, y: y, scale: scale)
        }
        try Task.checkCancellation()
        reply.complete(data ?? Self.transparentPNG, nil)
      } catch {
        reply.complete(nil, error)
      }
    }
    taskLock.unlock()
  }

  func cancelPendingLoads() {
    taskLock.lock()
    let tasks = Array(tileTasks.values)
    tileTasks.removeAll()
    taskLock.unlock()
    tasks.forEach { $0.cancel() }
  }

  private func finishTask(_ id: UUID) {
    taskLock.lock()
    tileTasks.removeValue(forKey: id)
    taskLock.unlock()
  }

  private func purgeDecodedTiles() {
    Task { await store.purgeCache() }
  }

  // A transparent 1x1 PNG is sufficient for a missing tile: MapKit stretches
  // it to the requested geometry. Never substitute a provider/network URL.
  private static let transparentPNG = Data(
    base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII="
  )!

  private final class TileReply: @unchecked Sendable {
    private let callback: (Data?, Error?) -> Void
    init(_ callback: @escaping (Data?, Error?) -> Void) { self.callback = callback }
    func complete(_ data: Data?, _ error: Error?) { callback(data, error) }
  }
}

final class BicinoContourLabelAnnotation: NSObject, MKAnnotation {
  let coordinate: CLLocationCoordinate2D
  let title: String?
  init(coordinate: CLLocationCoordinate2D, elevation: Int) {
    self.coordinate = coordinate
    self.title = "\(elevation) m"
  }
  static func view(on mapView: MKMapView, annotation: BicinoContourLabelAnnotation)
    -> MKAnnotationView
  {
    let view =
      mapView.dequeueReusableAnnotationView(withIdentifier: "contour-number")
      ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "contour-number")
    view.annotation = annotation
    let text = annotation.title ?? ""
    let font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    let size = (text as NSString).size(withAttributes: [.font: font])
    view.image = UIGraphicsImageRenderer(
      size: CGSize(width: size.width + 8, height: size.height + 4)
    ).image { _ in
      (text as NSString).draw(
        at: CGPoint(x: 4, y: 2),
        withAttributes: [
          .font: font, .foregroundColor: UIColor.brown, .strokeColor: UIColor.white,
          .strokeWidth: -4,
        ])
    }
    view.displayPriority = .defaultLow
    view.collisionMode = .rectangle
    view.isUserInteractionEnabled = false
    return view
  }
}

@MainActor final class BicinoContourLabels {
  private var task: Task<Void, Never>?
  private var generation = UUID()
  func clear(on mapView: MKMapView) {
    task?.cancel()
    generation = UUID()
    mapView.removeAnnotations(
      mapView.annotations.compactMap { $0 as? BicinoContourLabelAnnotation })
  }
  func update(on mapView: MKMapView, overlay: BicinoTopographyTileOverlay?) {
    task?.cancel()
    generation = UUID()
    guard let overlay, overlay.hasTerrainFeatures else {
      clear(on: mapView)
      return
    }
    // No useful readable label density at overview scale.
    guard mapView.visibleMapRect.width < MKMapSize.world.width / 128 else {
      clear(on: mapView)
      return
    }
    let token = generation
    let rect = mapView.visibleMapRect
    task = Task { [weak self, weak mapView] in
      do {
        try await Task.sleep(nanoseconds: 100_000_000)
        let anchors = try await overlay.labelAnchors(in: rect)
        try Task.checkCancellation()
        guard let self, let mapView, token == self.generation else { return }
        var reserved = mapView.annotations.filter { !($0 is BicinoContourLabelAnnotation) }.map {
          let p = mapView.convert($0.coordinate, toPointTo: mapView)
          return CGRect(x: p.x - 28, y: p.y - 28, width: 56, height: 56)
        }
        var segments: [(CGPoint, CGPoint)] = []
        for line in mapView.overlays.compactMap({ $0 as? MKPolyline }) {
          guard segments.count + line.pointCount <= 4096 else {
            self.clear(on: mapView)
            return
          }
          if line.pointCount < 2 { continue }
          for i in 1..<line.pointCount {
            segments.append(
              (
                mapView.convert(line.points()[i - 1].coordinate, toPointTo: mapView),
                mapView.convert(line.points()[i].coordinate, toPointTo: mapView)
              ))
          }
        }
        var annotations: [BicinoContourLabelAnnotation] = []
        for anchor in anchors {
          let coordinate = overlay.coordinate(worldX: Double(anchor.x), worldY: Double(anchor.y))
          let p = mapView.convert(coordinate, toPointTo: mapView)
          let textWidth = ("\(anchor.elevation) m" as NSString).size(withAttributes: [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
          ]).width + 8
          let box = CGRect(x: p.x - textWidth / 2, y: p.y - 10, width: textWidth, height: 20)
          guard mapView.bounds.insetBy(dx: 12, dy: 12).contains(box),
            !reserved.contains(where: { $0.intersects(box) })
          else { continue }
          let routeHit = segments.contains { a, b in
            let bounds = CGRect(
              x: min(a.x, b.x) - 12, y: min(a.y, b.y) - 12, width: abs(a.x - b.x) + 24,
              height: abs(a.y - b.y) + 24)
            return bounds.intersects(box)
          }
          if routeHit { continue }
          annotations.append(
            BicinoContourLabelAnnotation(coordinate: coordinate, elevation: anchor.elevation))
          reserved.append(box.insetBy(dx: -30, dy: -24))
          if annotations.count == 24 { break }
        }
        mapView.removeAnnotations(
          mapView.annotations.compactMap { $0 as? BicinoContourLabelAnnotation })
        mapView.addAnnotations(annotations)
      } catch is CancellationError {} catch {
        if let self, let mapView, self.generation == token { self.clear(on: mapView) }
      }
    }
  }
}

struct BicinoTerrainExperimentView: View {
  @Environment(\.dismiss) private var dismiss
  let overlay: BicinoTopographyTileOverlay
  @State var style: TerrainMapStyle
  @State private var contours = true
  @State private var grids: [TerrainGrid] = []
  @State private var loading = true
  @State private var failure = false
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker("Terrain", selection: $style) {
          ForEach(TerrainMapStyle.allCases.filter { $0 != .none }) { Text($0.title).tag($0) }
        }.pickerStyle(.menu).padding(.horizontal)
        if loading {
          ProgressView("Loading offline terrain…").frame(maxHeight: .infinity)
        } else if grids.isEmpty {
          Text(
            failure
              ? "The saved terrain could not be verified."
              : "Download a new topographic map with terrain data to use these experiments."
          )
          .padding().frame(maxHeight: .infinity)
        } else if style == .terrain3D {
          BicinoTerrainScene(grids: grids)
          Text(
            "Height surface only · drag to orbit, pinch to zoom. Navigation overlays are excluded from this experiment."
          )
          .font(.footnote).foregroundStyle(.secondary).padding()
        } else {
          Toggle("Contours and elevation numbers", isOn: $contours).padding(.horizontal)
          BicinoTerrainMap(overlay: overlay, grids: grids, style: style, contours: contours)
          Text(
            style == .slope
              ? "Slope: green 0° → brown 45° and steeper"
              : style == .elevationTint
                ? "Elevation tint: −200 m → 3,000 m · subtle hillshade"
                : "Hillshade · northwest light at 45°"
          )
          .font(.footnote).foregroundStyle(.secondary).padding(8)
        }
      }
      .navigationTitle("Terrain Experiments")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }.task {
      do { grids = try await overlay.terrain(near: overlay.coordinate) } catch is CancellationError
      { return } catch { failure = true }
      loading = false
    }
  }
}

private final class TerrainReliefOverlay: NSObject, MKOverlay {
  struct Cell {
    let points: [MKMapPoint]
    let shade: CGFloat
    let elevation: Int
    let slope: UInt8
  }
  let cells: [Cell]
  let coordinate: CLLocationCoordinate2D
  let boundingMapRect: MKMapRect
  init(source: BicinoTopographyTileOverlay, grids: [TerrainGrid]) {
    coordinate = source.coordinate
    boundingMapRect = source.boundingMapRect
    var result: [Cell] = []
    for grid in grids {
      for y in 0..<32 {
        for x in 0..<32 {
          let indices = [y * 33 + x, y * 33 + x + 1, (y + 1) * 33 + x + 1, (y + 1) * 33 + x]
          guard indices.allSatisfy({ grid.nodes[$0].height != -32768 }) else { continue }
          let points = indices.map { i in
            MKMapPoint(
              source.coordinate(
                worldX: Double(grid.x * 4096 + (i % 33) * 128),
                worldY: Double(grid.y * 4096 + (i / 33) * 128)))
          }
          let node = grid.nodes[indices[0]]
          result.append(
            Cell(
              points: points, shade: CGFloat(node.shade) / 255, elevation: node.height,
              slope: node.slope))
        }
      }
    }
    cells = result
  }
}

private final class TerrainReliefRenderer: MKOverlayRenderer {
  let style: TerrainMapStyle
  init(overlay: TerrainReliefOverlay, style: TerrainMapStyle) {
    self.style = style
    super.init(overlay: overlay)
  }
  override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
    guard let terrain = overlay as? TerrainReliefOverlay else { return }
    context.setAllowsAntialiasing(false)
    for cell in terrain.cells {
      let path = CGMutablePath()
      path.addLines(between: cell.points.map { point(for: $0) })
      path.closeSubpath()
      guard path.boundingBoxOfPath.intersects(rect(for: mapRect)) else { continue }
      let color: UIColor
      if style == .hillshade {
        color = UIColor(white: 0, alpha: (1 - cell.shade) * 0.3)
      } else {
        let t =
          style == .slope
          ? min(1, CGFloat(cell.slope) / 45) : min(1, max(0, CGFloat(cell.elevation + 200) / 3200))
        let light: CGFloat = style == .slope ? 1 : 0.75 + cell.shade * 0.25
        color = UIColor(
          red: (105 + 130 * t) / 255 * light, green: (180 - 55 * t) / 255 * light,
          blue: (110 - 25 * t) / 255 * light, alpha: 0.3)
      }
      context.addPath(path)
      context.setFillColor(color.cgColor)
      context.fillPath()
    }
  }
}

private struct BicinoTerrainMap: UIViewRepresentable {
  let overlay: BicinoTopographyTileOverlay
  let grids: [TerrainGrid]
  let style: TerrainMapStyle
  let contours: Bool
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> MKMapView {
    let map = MKMapView()
    map.delegate = context.coordinator
    context.coordinator.source = overlay
    if let grid = grids.first {
      map.setRegion(
        MKCoordinateRegion(
          center: overlay.coordinate(
            worldX: Double(grid.x * 4096 + 2048), worldY: Double(grid.y * 4096 + 2048)),
          latitudinalMeters: 4000, longitudinalMeters: 4000), animated: false)
    }
    return map
  }
  func updateUIView(_ map: MKMapView, context: Context) {
    guard context.coordinator.style != style || context.coordinator.contours != contours else {
      return
    }
    map.removeOverlays(map.overlays)
    context.coordinator.style = style
    context.coordinator.contours = contours
    let terrain = TerrainReliefOverlay(source: overlay, grids: grids)
    map.addOverlay(terrain, level: .aboveRoads)
    if contours { map.addOverlay(overlay, level: .aboveRoads) }
    context.coordinator.labels.update(on: map, overlay: contours ? overlay : nil)
  }
  static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
    coordinator.terrainTask?.cancel()
    coordinator.labels.clear(on: map)
    map.delegate = nil
  }
  @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
    var source: BicinoTopographyTileOverlay?
    var style: TerrainMapStyle?
    var contours = false
    var terrainTask: Task<Void, Never>?
    let labels = BicinoContourLabels()
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
      if let relief = overlay as? TerrainReliefOverlay {
        return TerrainReliefRenderer(overlay: relief, style: style ?? .hillshade)
      }
      if let tile = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tile) }
      return MKOverlayRenderer(overlay: overlay)
    }
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
      labels.update(on: mapView, overlay: contours ? source : nil)
      terrainTask?.cancel()
      guard let source else { return }
      let center = mapView.centerCoordinate
      terrainTask = Task { [weak self, weak mapView] in
        do {
          try await Task.sleep(for: .milliseconds(100))
          let grids = try await source.terrain(near: center)
          try Task.checkCancellation()
          guard let self, let mapView else { return }
          mapView.removeOverlays(mapView.overlays.filter { $0 is TerrainReliefOverlay })
          mapView.insertOverlay(
            TerrainReliefOverlay(source: source, grids: grids), at: 0, level: .aboveRoads)
          self.labels.update(on: mapView, overlay: self.contours ? source : nil)
        } catch { /* Cancellation or missing data leaves the base map readable. */  }
      }
    }
    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
      guard let label = annotation as? BicinoContourLabelAnnotation else { return nil }
      return BicinoContourLabelAnnotation.view(on: mapView, annotation: label)
    }
  }
}

private struct BicinoTerrainScene: UIViewRepresentable {
  let grids: [TerrainGrid]
  func makeUIView(context: Context) -> SCNView {
    let view = SCNView()
    view.backgroundColor = .systemBackground
    view.allowsCameraControl = true
    view.autoenablesDefaultLighting = true
    let scene = SCNScene()
    view.scene = scene
    guard let first = grids.first else { return view }
    let originX = Double(first.x * 4096 + 2048)
    let originY = Double(first.y * 4096 + 2048)
    let groundScale = cos(atan(sinh(originY / 6_378_137))) / 1000
    let heights = grids.flatMap { $0.nodes.filter { $0.height != -32768 }.map(\.height) }
    let base = Double(heights.min() ?? 0)
    for grid in grids {
      var vertices: [SCNVector3] = []
      var normals: [SCNVector3] = []
      for y in 0..<33 {
        for x in 0..<33 {
          let node = grid.nodes[y * 33 + x]
          vertices.append(
            SCNVector3(
              Float((Double(grid.x * 4096 + x * 128) - originX) * groundScale),
              Float((Double(node.height == -32768 ? Int(base) : node.height) - base) / 1000),
              Float(-(Double(grid.y * 4096 + y * 128) - originY) * groundScale)))
          let left = grid.nodes[y * 33 + max(0, x - 1)].height
          let right = grid.nodes[y * 33 + min(32, x + 1)].height
          let south = grid.nodes[max(0, y - 1) * 33 + x].height
          let north = grid.nodes[min(32, y + 1) * 33 + x].height
          let nx =
            left == -32768 || right == -32768
            ? 0 : Float(left - right) / Float(256 * groundScale * 1000)
          let nz =
            south == -32768 || north == -32768
            ? 0 : Float(north - south) / Float(256 * groundScale * 1000)
          let length = sqrt(nx * nx + 1 + nz * nz)
          normals.append(SCNVector3(nx / length, 1 / length, nz / length))
        }
      }
      var indices: [UInt32] = []
      for y in 0..<32 {
        for x in 0..<32 {
          let a = y * 33 + x
          let b = a + 1
          let c = a + 33
          let d = c + 1
          if [a, b, c, d].allSatisfy({ grid.nodes[$0].height != -32768 }) {
            indices += [UInt32(a), UInt32(b), UInt32(c), UInt32(b), UInt32(d), UInt32(c)]
          }
        }
      }
      let geometry = SCNGeometry(
        sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(normals: normals)],
        elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
      let material = SCNMaterial()
      material.diffuse.contents = UIColor(red: 0.55, green: 0.66, blue: 0.43, alpha: 1)
      material.isDoubleSided = true
      geometry.materials = [material]
      scene.rootNode.addChildNode(SCNNode(geometry: geometry))
    }
    let camera = SCNNode()
    camera.camera = SCNCamera()
    camera.camera?.zFar = 200
    camera.position = SCNVector3(0, 8, 8)
    camera.look(at: SCNVector3(0, 0, 0))
    scene.rootNode.addChildNode(camera)
    view.pointOfView = camera
    return view
  }
  func updateUIView(_ view: SCNView, context: Context) {}
}
