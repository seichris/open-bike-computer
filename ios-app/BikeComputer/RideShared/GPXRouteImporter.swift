import Foundation

enum GPXRouteImporterError: Error, Equatable, LocalizedError {
    case fileTooLarge
    case malformedXML
    case invalidCoordinate
    case tooManyPoints
    case noUsableRoute
    case invalidRoute

    var errorDescription: String? {
        switch self {
        case .fileTooLarge: "The GPX file exceeds the 4 MiB route limit."
        case .malformedXML: "The GPX file is malformed."
        case .invalidCoordinate: "The GPX file contains an invalid coordinate."
        case .tooManyPoints: "The GPX route contains too many points."
        case .noUsableRoute: "The GPX file has no usable route or track segment."
        case .invalidRoute: "The GPX geometry cannot be used by Bicino."
        }
    }
}

enum GPXRouteImportSourceV1: Equatable {
    case local(createdAt: Date)
    case strava(receipt: StravaRouteImportReceiptV1)

    var provider: RouteProviderMetadataV1 {
        switch self {
        case .local: RouteProviderPolicyV1.importedGPX
        case .strava: RouteProviderPolicyV1.strava
        }
    }

    var sourceReference: RouteSourceReferenceV1? {
        switch self {
        case .local: nil
        case .strava(let receipt): receipt.routeURL.sourceReference
        }
    }

    var createdAt: Date {
        switch self {
        case .local(let createdAt): createdAt
        case .strava(let receipt): receipt.fetchedAt
        }
    }

    var deleteAfter: Date? {
        switch self {
        case .local: nil
        case .strava(let receipt): receipt.deleteAfter
        }
    }

    var startFallback: String {
        switch self {
        case .local: "GPX start"
        case .strava: "Strava start"
        }
    }

    var destinationFallback: String {
        switch self {
        case .local: "GPX destination"
        case .strava: "Strava destination"
        }
    }

    var followInstruction: String {
        switch self {
        case .local: "Follow imported GPX route"
        case .strava: "Follow Strava route"
        }
    }
}

enum GPXRouteImporterV1 {
    static let maximumInputBytes = 4 * 1_024 * 1_024

    static func archive(
        data: Data,
        fallbackName: String,
        routeID: UUID = UUID(),
        createdAt: Date = Date(),
        localeIdentifier: String = Locale.current.identifier
    ) throws -> NavigationRouteArchiveV1 {
        try archive(
            data: data,
            fallbackName: fallbackName,
            routeID: routeID,
            revision: 1,
            source: .local(createdAt: createdAt),
            localeIdentifier: localeIdentifier
        )
    }

    static func archive(
        data: Data,
        fallbackName: String,
        routeID: UUID,
        revision: UInt32,
        source importSource: GPXRouteImportSourceV1,
        localeIdentifier: String = Locale.current.identifier
    ) throws -> NavigationRouteArchiveV1 {
        guard !data.isEmpty, data.count <= maximumInputBytes else {
            throw GPXRouteImporterError.fileTooLarge
        }
        let collector = GPXCollector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw collector.failure ?? .malformedXML
        }
        if let failure = collector.failure { throw failure }

        let routeCandidates = collector.routeSelections.map {
            GPXSelection(points: deduplicated($0.points), name: $0.name)
        }
        let trackCandidates = collector.trackSelections.map {
            GPXSelection(points: deduplicated($0.points), name: $0.name)
        }
        let selected: GPXSelection
        if let route = routeCandidates.max(by: {
            $0.points.count < $1.points.count
        }), route.points.count >= 2 {
            selected = route
        } else if let track = trackCandidates.max(by: {
            $0.points.count < $1.points.count
        }), track.points.count >= 2 {
            selected = track
        } else {
            throw GPXRouteImporterError.noUsableRoute
        }

        let pointsWithNames = deduplicated(selected.points)
        let points = pointsWithNames.map(\.coordinate)
        guard points.count <= NavigationRouteLimitsV1.production.maximumPoints
        else { throw GPXRouteImporterError.tooManyPoints }
        guard let bounds = RouteBoundsV1.enclosing(points) else {
            throw GPXRouteImporterError.noUsableRoute
        }
        let cumulative = NavigationGeometryV1.cumulativeDistances(for: points)
        guard let distance = cumulative.last, distance > 0 else {
            throw GPXRouteImporterError.noUsableRoute
        }

        let importedName = normalizedLabel(
            selected.name,
            fallback: normalizedFallbackName(fallbackName)
        )
        let destinationName = normalizedLabel(
            pointsWithNames.last?.name,
            fallback: importSource.destinationFallback
        )
        let route = NavigationRouteV1(
            id: routeID,
            revision: revision,
            provider: importSource.provider,
            sourceReference: importSource.sourceReference,
            localeIdentifier: localeIdentifier,
            transportType: .cycling,
            source: RouteEndpointV1(
                coordinate: points[0],
                label: normalizedLabel(
                    pointsWithNames.first?.name,
                    fallback: importSource.startFallback
                )
            ),
            destination: RouteEndpointV1(
                coordinate: points[points.count - 1],
                label: destinationName
            ),
            bounds: bounds,
            distanceMeters: distance,
            expectedTravelTimeSeconds: nil,
            name: importedName,
            points: points,
            steps: steps(
                points: pointsWithNames,
                cumulativeDistances: cumulative,
                destinationName: destinationName,
                followInstruction: importSource.followInstruction
            ),
            normalizationVersion: 1
        )
        do {
            return try NavigationRouteArchiveV1.create(
                route: route,
                createdAt: importSource.createdAt,
                deleteAfter: importSource.deleteAfter,
                purpose: .offlineNavigation
            )
        } catch {
            throw GPXRouteImporterError.invalidRoute
        }
    }

    private static func steps(
        points: [GPXPoint],
        cumulativeDistances: [Double],
        destinationName: String,
        followInstruction: String
    ) -> [NavigationRouteStepV1] {
        let lastIndex = points.count - 1
        let namedIntermediateIndices = points.indices.dropFirst().dropLast()
            .filter { points[$0].name?.isEmpty == false }
            .prefix(NavigationRouteLimitsV1.production.maximumSteps - 2)
        var boundaries = Array(namedIntermediateIndices)
        if boundaries.isEmpty {
            boundaries.append(max(lastIndex - 1, 0))
        }
        if boundaries.last != lastIndex { boundaries.append(lastIndex) }

        var result: [NavigationRouteStepV1] = []
        var startIndex = 0
        for endIndex in boundaries {
            let isFinal = endIndex == lastIndex
            let pointName = points[endIndex].name
            let instruction: String
            let maneuver: ManeuverV1
            if isFinal {
                instruction = "Arrive at \(destinationName)"
                maneuver = .arrive
            } else if let pointName, !pointName.isEmpty {
                instruction = "Continue to \(pointName)"
                maneuver = .straight
            } else {
                instruction = followInstruction
                maneuver = .straight
            }
            result.append(NavigationRouteStepV1(
                id: UInt32(result.count + 1),
                geometryStartIndex: startIndex,
                geometryEndIndex: endIndex,
                instruction: instruction,
                maneuver: maneuver,
                distanceMeters: max(
                    cumulativeDistances[endIndex] -
                        cumulativeDistances[startIndex],
                    0
                )
            ))
            startIndex = endIndex
        }
        return result
    }

    private static func deduplicated(
        _ points: [RouteCoordinateV1]
    ) -> [RouteCoordinateV1] {
        points.reduce(into: []) { result, point in
            if result.last != point { result.append(point) }
        }
    }

    private static func deduplicated(_ points: [GPXPoint]) -> [GPXPoint] {
        points.reduce(into: []) { result, point in
            if result.last?.coordinate == point.coordinate {
                if result[result.count - 1].name == nil, point.name != nil {
                    result[result.count - 1] = point
                }
            } else {
                result.append(point)
            }
        }
    }

    private static func normalizedFallbackName(_ value: String) -> String {
        let base = (value as NSString).deletingPathExtension
        return normalizedLabel(base, fallback: "Imported GPX route")
    }

    private static func normalizedLabel(
        _ value: String?,
        fallback: String
    ) -> String {
        let trimmed = value?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        return String((trimmed.isEmpty ? fallback : trimmed).prefix(200))
    }
}

private struct GPXPoint {
    let coordinate: RouteCoordinateV1
    var name: String?
}

private struct GPXSelection {
    let points: [GPXPoint]
    let name: String?
}

private final class GPXCollector: NSObject, XMLParserDelegate {
    var routeSelections: [GPXSelection] = []
    var trackSelections: [GPXSelection] = []
    var failure: GPXRouteImporterError?

    private var elements: [String] = []
    private var currentRoutePoints: [GPXPoint]?
    private var currentRouteName: String?
    private var currentTrackName: String?
    private var currentTrackSegment: [RouteCoordinateV1]?
    private var capturedText = ""
    private var pointCount = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        elements.append(elementName)
        if elementName == "rte" {
            currentRoutePoints = []
            currentRouteName = nil
        } else if elementName == "trk" {
            currentTrackName = nil
        } else if elementName == "trkseg" {
            currentTrackSegment = []
        }
        if elementName == "name" {
            capturedText = ""
        }
        guard elementName == "rtept" || elementName == "trkpt" else {
            return
        }
        guard let latitudeText = attributeDict["lat"],
              let longitudeText = attributeDict["lon"],
              let latitude = Double(latitudeText),
              let longitude = Double(longitudeText) else {
            fail(.invalidCoordinate, parser: parser)
            return
        }
        let coordinate = RouteCoordinateV1(
            latitude: latitude,
            longitude: longitude
        )
        guard coordinate.isValid else {
            fail(.invalidCoordinate, parser: parser)
            return
        }
        pointCount += 1
        guard pointCount <= NavigationRouteLimitsV1.production.maximumPoints
        else {
            fail(.tooManyPoints, parser: parser)
            return
        }
        if elementName == "rtept" {
            currentRoutePoints?.append(GPXPoint(
                coordinate: coordinate,
                name: nil
            ))
        } else {
            currentTrackSegment?.append(coordinate)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard elements.last == "name" else { return }
        capturedText.append(string)
    }

    func parser(
        _ parser: XMLParser,
        foundInternalEntityDeclarationWithName name: String,
        value: String?
    ) {
        fail(.malformedXML, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        foundExternalEntityDeclarationWithName name: String,
        publicID: String?,
        systemID: String?
    ) {
        fail(.malformedXML, parser: parser)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let parent = elements.dropLast().last
        if elementName == "name" {
            let value = String(capturedText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).prefix(200))
            if !value.isEmpty {
                switch parent {
                case "rtept":
                    if let index = currentRoutePoints?.indices.last {
                        currentRoutePoints?[index].name = value
                    }
                case "rte":
                    currentRouteName = currentRouteName ?? value
                case "trk":
                    currentTrackName = currentTrackName ?? value
                default:
                    break
                }
            }
            capturedText = ""
        } else if elementName == "rte", let currentRoutePoints {
            routeSelections.append(GPXSelection(
                points: currentRoutePoints,
                name: currentRouteName
            ))
            self.currentRoutePoints = nil
            currentRouteName = nil
        } else if elementName == "trkseg", let currentTrackSegment {
            trackSelections.append(GPXSelection(
                points: currentTrackSegment.map {
                    GPXPoint(coordinate: $0, name: nil)
                },
                name: currentTrackName
            ))
            self.currentTrackSegment = nil
        } else if elementName == "trk" {
            currentTrackName = nil
        }
        if elements.last == elementName { elements.removeLast() }
    }

    private func fail(
        _ error: GPXRouteImporterError,
        parser: XMLParser
    ) {
        failure = error
        parser.abortParsing()
    }
}
