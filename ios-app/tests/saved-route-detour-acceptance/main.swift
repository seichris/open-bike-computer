import CoreLocation
import Foundation
import MapKit

// Live acceptance of a saved-route bicycle detour, built from the app's own
// shared code: the GPX importer, the saved-route runtime, the detour engine
// and the provider chain. It rides a saved GPX route, leaves it, lets the
// engine ask Apple MapKit for cycling directions (live) and, when MapKit has
// no cycling route, the authenticated Bicino endpoint (live), follows the
// returned detour and requires a confirmed rejoin before original guidance
// resumes. Usage:
//
//   saved-route-detour-acceptance <route.gpx> <evidence.json>
//
// Environment: BICINO_SERVICE_URL (e.g. https://maps-dev.8o.vc),
// BICINO_INSTALLATION_ID, BICINO_INSTALLATION_TOKEN (never printed),
// optional LEAVE_AFTER_METERS (default 600), LEAVE_BEARING_OFFSET (default 90,
// relative to the route) or LEAVE_BEARING (absolute, e.g. straight on past a
// turn), and LEAVE_DISTANCE_METERS (default 200).

@MainActor
final class RecordingDirections: BicycleDetourDirectionsCalculating {
    private let inner: MapKitBicycleDetourDirections
    let transportType: MKDirectionsTransportType
    static var records: [[String: Any]] = []

    init(request: MKDirections.Request) {
        inner = MapKitBicycleDetourDirections(request: request)
        transportType = request.transportType
    }

    func calculate() async throws -> [MKRoute] {
        do {
            let routes = try await inner.calculate()
            Self.records.append(["transportType": Int(transportType.rawValue), "result": "routes", "count": routes.count])
            return routes
        } catch {
            let ns = error as NSError
            Self.records.append([
                "transportType": Int(transportType.rawValue),
                "result": "error",
                "domain": ns.domain,
                "code": ns.code,
                "MKDirectionsErrorCode": (ns.userInfo[CyclingDirectionsFallback.directionsErrorCodeKey] as? NSNumber)?.intValue as Any,
                "reason": ns.localizedFailureReason ?? ns.localizedDescription,
            ])
            throw error
        }
    }

    func cancel() { inner.cancel() }
}

@MainActor
final class LiveServiceTransport: BicycleDetourServiceTransporting {
    let baseURL: URL
    let installationID: String
    let token: String
    var exchanges: [[String: Any]] = []

    init(baseURL: URL, installationID: String, token: String) {
        self.baseURL = baseURL
        self.installationID = installationID
        self.token = token
    }

    func post(_ request: BicycleDetourServiceRequestV1) async throws -> BicycleDetourHTTPResponseV1 {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/bicycle-detours"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "clientInstallationId", value: installationID)]
        var urlRequest = URLRequest(url: components.url!)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(token, forHTTPHeaderField: "X-Installation-Token")
        let body = try JSONEncoder().encode(request)
        urlRequest.httpBody = body
        let started = Date()
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let http = response as! HTTPURLResponse
        let sent = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        exchanges.append([
            "status": http.statusCode,
            "elapsedSeconds": (Date().timeIntervalSince(started) * 1000).rounded() / 1000,
            "cacheControl": http.value(forHTTPHeaderField: "Cache-Control") ?? "",
            "requestFields": sent.keys.sorted(),
            "requestCoordinates": 2,
            "routeSource": request.routeSource,
            "responseBytes": data.count,
        ])
        return BicycleDetourHTTPResponseV1(
            statusCode: http.statusCode,
            cacheControl: http.value(forHTTPHeaderField: "Cache-Control"),
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            body: data
        )
    }
}

func offset(_ coordinate: RouteCoordinateV1, meters: Double, bearing: Double) -> RouteCoordinateV1 {
    let radius = NavigationGeometryV1.earthRadiusMeters
    let angular = meters / radius
    let heading = bearing * .pi / 180
    let lat1 = coordinate.latitude * .pi / 180
    let lon1 = coordinate.longitude * .pi / 180
    let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(heading))
    let lon2 = lon1 + atan2(sin(heading) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin(lat2))
    return RouteCoordinateV1(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
}

/// Fixes every `spacing` metres along a polyline at 5 m/s.
func fixes(along points: [RouteCoordinateV1], from startTime: Date, spacing: Double = 10) -> [NavigationLocationSampleV1] {
    var result: [NavigationLocationSampleV1] = []
    var time = startTime
    for index in 0..<(points.count - 1) {
        let a = points[index], b = points[index + 1]
        let length = NavigationGeometryV1.distance(from: a, to: b)
        guard length > 0.5 else { continue }
        let bearing = SavedRouteGeometryV1.bearing(from: a, to: b)
        var travelled = 0.0
        while travelled < length {
            let coordinate = offset(a, meters: travelled, bearing: bearing)
            result.append(NavigationLocationSampleV1(
                coordinate: coordinate, horizontalAccuracyMeters: 5, courseDegrees: bearing,
                speedMetersPerSecond: 5, altitudeMeters: 5, timestamp: time
            ))
            time.addTimeInterval(spacing / 5)
            travelled += spacing
        }
    }
    return result
}

@MainActor
func run() async -> Int32 {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else {
        FileHandle.standardError.write("usage: saved-route-detour-acceptance <route.gpx> <evidence.json>\n".data(using: .utf8)!)
        return 64
    }
    let environment = ProcessInfo.processInfo.environment
    guard let base = environment["BICINO_SERVICE_URL"].flatMap(URL.init(string:)),
          let installationID = environment["BICINO_INSTALLATION_ID"],
          let token = environment["BICINO_INSTALLATION_TOKEN"] else {
        FileHandle.standardError.write("missing BICINO_SERVICE_URL / BICINO_INSTALLATION_ID / BICINO_INSTALLATION_TOKEN\n".data(using: .utf8)!)
        return 64
    }
    let leaveAfter = Double(environment["LEAVE_AFTER_METERS"] ?? "") ?? 600
    let leaveOffset = Double(environment["LEAVE_BEARING_OFFSET"] ?? "") ?? 90
    let absoluteLeaveBearing = Double(environment["LEAVE_BEARING"] ?? "")
    let leaveDistance = Double(environment["LEAVE_DISTANCE_METERS"] ?? "") ?? 200

    let gpx = try! Data(contentsOf: URL(fileURLWithPath: arguments[1]))
    let imported = try! GPXRouteImporterV1.importRoute(
        data: gpx, fallbackName: "Dubai acceptance", source: .local(createdAt: Date()), localeIdentifier: "en_AE"
    )
    let saved = imported.archive.route
    var evidence: [String: Any] = [
        "savedRoute": [
            "provider": saved.provider.providerID,
            "points": saved.points.count,
            "steps": saved.steps.count,
            "distanceMeters": saved.distanceMeters.rounded(),
            "contentHash": imported.archive.contentHash,
        ],
    ]

    var runtime = NavigationRuntimeV1()
    _ = try! runtime.start(route: saved, contentHash: imported.archive.contentHash, mode: .offline,
                           initialStepStrategy: .nearestUnambiguous, initialLocation: nil)
    let generation = runtime.generation
    var detourRuntime = NavigationRuntimeV1()
    var engine = SavedRouteDetourEngineV1(route: saved)
    let geometry = engine.geometry

    let transport = LiveServiceTransport(baseURL: base, installationID: installationID, token: token)
    let chain = BicycleDetourProviderChainV1(
        mapKit: MapKitCyclingDetourProvider { RecordingDirections(request: $0) },
        fallback: BicinoBicycleDetourProvider(transport: transport)
    )
    let routeSource = RouteProviderPolicyV1.bicycleDetourRouteSource(saved.provider)!

    var log: [[String: Any]] = []
    var lastSample: NavigationLocationSampleV1!
    var rejoin: SavedRouteRejoinV1?
    var detourRoute: NavigationRouteV1?
    var pendingRequest: SavedRouteDetourRequestV1?
    var savedSnapshotAfterResume: NavigationSnapshotV1?
    var trace: [[Double]] = []
    var detourInstructions: [String] = []

    func feed(_ fix: NavigationLocationSampleV1) {
        lastSample = fix
        trace.append([fix.coordinate.latitude, fix.coordinate.longitude])
        let savedSnapshot = engine.isHoldingSavedRoute ? nil : try? runtime.process(fix)
        let detourSnapshot = engine.phase == .following ? try? detourRuntime.process(fix) : nil
        if let detourSnapshot, detourInstructions.last != detourSnapshot.instruction {
            detourInstructions.append(detourSnapshot.instruction)
        }
        let effects = engine.observe(fix, savedRouteSnapshot: savedSnapshot, detourSnapshot: detourSnapshot,
                                     now: fix.timestamp)
        handle(effects)
    }

    func handle(_ effects: [SavedRouteDetourEffectV1]) {
        for effect in effects {
            switch effect {
            case .requestDetour(let request):
                pendingRequest = request
                log.append(["event": "requestDetour", "target": "\(request.target.kind)",
                            "targetAlongMeters": request.target.distanceAlongMeters.rounded(),
                            "windowUpperMeters": request.target.windowUpperMeters.rounded()])
            case .cancelRequest(let id):
                log.append(["event": "cancelRequest", "id": id])
            case .startDetour(let route):
                detourRoute = route
                _ = try! detourRuntime.start(route: route, mode: .online, initialStepStrategy: .first, initialLocation: lastSample)
                log.append(["event": "startDetour", "provider": route.provider.providerID,
                            "attribution": route.provider.attribution, "points": route.points.count,
                            "steps": route.steps.count, "distanceMeters": route.distanceMeters.rounded(),
                            "lastStep": route.steps.last!.instruction])
            case .endDetour:
                detourRuntime.stop()
                log.append(["event": "endDetour"])
            case .resumeSavedRoute(let confirmed):
                rejoin = confirmed
                savedSnapshotAfterResume = try! runtime.resume(atDistanceAlongGeometry: confirmed.distanceAlongMeters,
                                                               currentLocation: lastSample)
                log.append(["event": "resumeSavedRoute", "alongMeters": confirmed.distanceAlongMeters.rounded(),
                            "beyondWindow": confirmed.isBeyondWindow,
                            "skippedStops": confirmed.skippedStopDistances.count])
            }
        }
    }

    // 1. Ride the saved route up to the leave point.
    let start = Date()
    let onRoute = fixes(along: saved.points, from: start)
    var index = 0
    while index < onRoute.count {
        feed(onRoute[index])
        index += 1
        if (runtime.snapshot?.distanceAlongGeometryMeters ?? 0) >= leaveAfter { break }
    }
    let leavePoint = lastSample.coordinate
    let leaveSegment = geometry.segmentIndex(atDistance: engine.confirmedProgressMeters)
    let routeBearing = geometry.bearing(ofSegment: leaveSegment) ?? 0
    let leaveBearing = absoluteLeaveBearing ?? (routeBearing + leaveOffset).truncatingRemainder(dividingBy: 360)
    evidence["leave"] = ["alongMeters": engine.confirmedProgressMeters.rounded(), "bearing": leaveBearing.rounded(),
                         "distanceMeters": leaveDistance]

    // 2. Leave the route.
    let offPath = (0...Int(leaveDistance / 10)).map { offset(leavePoint, meters: Double($0) * 10, bearing: leaveBearing) }
    var time = lastSample.timestamp.addingTimeInterval(2)
    for coordinate in offPath.dropFirst() {
        feed(NavigationLocationSampleV1(coordinate: coordinate, horizontalAccuracyMeters: 5, courseDegrees: leaveBearing,
                                        speedMetersPerSecond: 5, altitudeMeters: 5, timestamp: time))
        time.addTimeInterval(2)
        if pendingRequest != nil { break }
    }
    guard let request = pendingRequest else {
        evidence["result"] = "FAILED: no detour request"; evidence["log"] = log
        write(evidence, to: arguments[2]); return 1
    }

    // 3. Live providers: MapKit cycling first, then the authenticated endpoint.
    let query = BicycleDetourQueryV1(request: request, routeSource: routeSource, localeIdentifier: "en_AE")
    let outcome = await chain.detour(for: query)
    evidence["mapKit"] = ["requests": RecordingDirections.records,
                          "outcome": "\(chain.lastMapKitOutcome.map { String(describing: $0) } ?? "none")"]
    evidence["bicinoService"] = ["url": base.absoluteString + BicycleDetourServiceContractV1.path,
                                 "exchanges": transport.exchanges]
    switch outcome {
    case .route(let route): evidence["providerOutcome"] = "route from \(route.provider.providerID)"
    default: evidence["providerOutcome"] = String(describing: outcome)
    }
    handle(engine.complete(requestID: request.id, outcome: outcome, latestSample: lastSample, now: lastSample.timestamp))
    guard let detour = detourRoute else {
        evidence["result"] = "FAILED: no detour started"; evidence["log"] = log
        write(evidence, to: arguments[2]); return 1
    }

    // 4. Follow the detour, then continue along the saved route until a
    // confirmed rejoin resumes original guidance.
    time = lastSample.timestamp.addingTimeInterval(2)
    for fix in fixes(along: detour.points, from: time) {
        feed(fix)
        if rejoin != nil { break }
    }
    if rejoin == nil {
        let target = request.target.distanceAlongMeters
        let ahead = saved.points.enumerated().filter { geometry.cumulative[$0.offset] >= target - 5 }.map(\.element)
        for fix in fixes(along: ahead, from: lastSample.timestamp.addingTimeInterval(2)) {
            feed(fix)
            if rejoin != nil { break }
        }
    }
    evidence["detourInstructions"] = detourInstructions
    evidence["log"] = log
    guard let rejoin, let resumed = savedSnapshotAfterResume else {
        evidence["result"] = "FAILED: no confirmed rejoin"
        write(evidence, to: arguments[2]); return 1
    }
    evidence["rejoin"] = [
        "alongMeters": rejoin.distanceAlongMeters.rounded(),
        "targetAlongMeters": request.target.distanceAlongMeters.rounded(),
        "savedRouteGenerationPreserved": resumed.navigationGeneration == generation,
        "contentHashPreserved": resumed.contentHash == imported.archive.contentHash,
        "resumedStepIndex": resumed.currentStepIndex,
        "resumedInstruction": resumed.instruction,
        "offRoute": resumed.offRouteDistanceMeters != nil,
        "detourActiveAfterRejoin": engine.detour != nil,
        "phase": "\(engine.phase)",
    ]
    let passed = resumed.navigationGeneration == generation && resumed.offRouteDistanceMeters == nil &&
        engine.phase == .onRoute && engine.detour == nil
    evidence["result"] = passed ? "PASSED" : "FAILED: resume state"
    if let traceOut = environment["TRACE_OUT"] {
        // The ridden positions, for replaying the same ride on a device.
        let data = try! JSONSerialization.data(withJSONObject: trace)
        try! data.write(to: URL(fileURLWithPath: traceOut))
    }
    write(evidence, to: arguments[2])
    return passed ? 0 : 1
}

func write(_ evidence: [String: Any], to path: String) {
    let data = try! JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
    print(String(data: data, encoding: .utf8)!)
}

let status = await run()
exit(status)
