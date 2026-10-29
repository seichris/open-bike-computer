import Foundation

nonisolated enum RouteElevationClientError: Error, Equatable {
    case invalidResponse
    case offline
    case cancelled
    case rejected(code: String)
    case rateLimited(retryAfterSeconds: Int?)
    case unavailable(retryAfterSeconds: Int?)

    /// Classifies transport and credential failures without exposing them.
    static func classify(_ error: Error) -> RouteElevationClientError {
        if let known = error as? RouteElevationClientError { return known }
        if error is CancellationError { return .cancelled }
        guard let urlError = error as? URLError else { return .unavailable(retryAfterSeconds: nil) }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .cannotFindHost, .dnsLookupFailed,
             .cannotConnectToHost:
            return .offline
        case .cancelled:
            return .cancelled
        default:
            return .unavailable(retryAfterSeconds: nil)
        }
    }
}

/// Validates one HTTP answer from the route elevation endpoint. Pure, so the
/// exact acceptance rules are host-tested without a network session.
nonisolated enum RouteElevationResponseDecoderV1 {
    static let maximumResponseBytes = 2 * 1_024 * 1_024
    static let maximumAttempts = 8

    static func decode(
        statusCode: Int,
        cacheControl: String?,
        contentType: String?,
        retryAfter: String?,
        body: Data
    ) throws -> RouteElevationServiceResponseV1 {
        guard statusCode == 200 else {
            let seconds = retryAfter.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                .map { min(max($0, 1), 86_400) }
            switch statusCode {
            case 400, 413, 422:
                throw RouteElevationClientError.rejected(code: backendCode(body) ?? "route_elevation_invalid_request")
            case 429:
                throw RouteElevationClientError.rateLimited(retryAfterSeconds: seconds)
            default:
                throw RouteElevationClientError.unavailable(retryAfterSeconds: seconds)
            }
        }
        let mediaType = (contentType ?? "").split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard cacheControl?.lowercased() == "private, no-store",
              mediaType == "application/json",
              body.count <= maximumResponseBytes,
              let decoded = try? JSONDecoder().decode(RouteElevationServiceResponseV1.self, from: body) else {
            throw RouteElevationClientError.invalidResponse
        }
        let ready = decoded.status == "ready"
        guard decoded.schema == RouteElevationContractV1.responseSchema,
              ready || decoded.status == "unavailable",
              ready == (decoded.profile != nil),
              decoded.attempts.count <= maximumAttempts else {
            throw RouteElevationClientError.invalidResponse
        }
        return decoded
    }

    private nonisolated struct ErrorEnvelope: Decodable {
        nonisolated struct Detail: Decodable { let code: String }
        let detail: Detail
    }

    static func backendCode(_ data: Data) -> String? {
        guard data.count <= 64 * 1_024,
              let code = try? JSONDecoder().decode(ErrorEnvelope.self, from: data).detail.code,
              !code.isEmpty, code.utf8.count <= 64,
              code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return code
    }
}

@MainActor
protocol RouteElevationProfileFetching: AnyObject {
    func fetchProfile(_ request: RouteElevationServiceRequestV1) async throws -> RouteElevationServiceResponseV1
}

/// Saved-route storage the elevation service may read and annotate. Sidecars
/// are bound to one exact archive and never hold coordinates.
@MainActor
protocol RouteElevationSidecarProviding: AnyObject {
    func elevationSidecar(for binding: RouteElevationArchiveBindingV1) -> RouteElevationSidecarV1?
    func storeElevationProfile(_ profile: RouteElevationProfileV1, for binding: RouteElevationArchiveBindingV1)
    func elevationSubject(for binding: RouteElevationArchiveBindingV1) -> RouteElevationSubjectV1?
}

/// One route whose elevation is wanted. `binding` names a durable saved
/// archive; unsaved routes carry no binding and are never written to disk.
nonisolated struct RouteElevationSubjectV1: Equatable {
    let route: NavigationRouteV1
    let binding: RouteElevationArchiveBindingV1?
    let gpxVertexElevations: [Double?]?

    init(
        route: NavigationRouteV1,
        binding: RouteElevationArchiveBindingV1? = nil,
        gpxVertexElevations: [Double?]? = nil
    ) {
        self.route = route
        self.binding = binding
        self.gpxVertexElevations = gpxVertexElevations
    }

    var cacheKey: String {
        "\(route.id.uuidString)|\(route.revision)|\(binding?.contentHash ?? "-")"
    }
}

nonisolated enum RouteElevationUnavailableReasonV1: Equatable, Sendable {
    /// Apple Maps routes, and Strava routes without usable GPX heights.
    case sourceNotPermitted
    case offline
    case serviceUnavailable
    case rateLimited(retryAfterSeconds: Int?)
    /// The terrain sources answered but cover too little of the route.
    case noCoverage
    case routeNotSupported

    var deviceReason: RouteElevationDeviceProtocolV1.Reason {
        switch self {
        case .sourceNotPermitted: .sourceNotPermitted
        case .offline: .offline
        case .serviceUnavailable: .serviceUnavailable
        case .rateLimited: .quotaExhausted
        case .noCoverage: .noCoverage
        case .routeNotSupported: .routeTooLong
        }
    }
}

nonisolated enum RouteElevationStateV1: Equatable, Sendable {
    case loading
    case ready(RouteElevationProfileV1)
    case unavailable(RouteElevationUnavailableReasonV1)

    var profile: RouteElevationProfileV1? {
        if case .ready(let profile) = self { return profile }
        return nil
    }
}

/// Geometry digest plus, when trusted GPX heights exist, the on-phone profile.
/// Pure and nonisolated so long routes are prepared off the main actor.
nonisolated enum RouteElevationPreparationV1 {
    nonisolated struct Prepared: Sendable {
        let geometry: RouteElevationGeometryV1
        let localProfile: RouteElevationProfileV1?
    }

    static func prepare(
        points: [RouteCoordinateV1],
        maximumPoints: Int,
        gpxVertexElevations: [Double?]?
    ) -> Prepared? {
        guard let geometry = try? RouteElevationProcessorV1.geometry(
            points: points, maximumPoints: maximumPoints
        ) else { return nil }
        guard let heights = gpxVertexElevations, heights.count == geometry.pointCount,
              case .trusted(let cleaned) = RouteElevationGPXTrustV1.evaluate(
                  vertexElevations: heights, cumulativeMeters: geometry.cumulativeMeters
              ) else {
            return Prepared(geometry: geometry, localProfile: nil)
        }
        let plan = RouteElevationProcessorV1.plan(length: geometry.lengthMeters)
        guard let raw = RouteElevationProcessorV1.resampleVertexElevations(
            geometry: geometry, plan: plan, vertexElevations: cleaned
        ), let profile = RouteElevationProcessorV1.process(
            geometry: geometry, plan: plan, rawElevations: raw, source: RouteElevationGPXTrustV1.source
        ), profile.isAvailable else {
            return Prepared(geometry: geometry, localProfile: nil)
        }
        return Prepared(geometry: geometry, localProfile: profile)
    }

    static func request(
        for geometry: RouteElevationGeometryV1, requestID: UUID, routeSource: String
    ) -> RouteElevationServiceRequestV1 {
        RouteElevationServiceRequestV1(
            schema: RouteElevationContractV1.requestSchema,
            requestId: requestID.uuidString.lowercased(),
            geometry: .init(
                crs: "EPSG:4326",
                // GeoJSON axis order, as the backend parses it: [lonE6, latE6].
                coordinatesE6: zip(geometry.longitudeE6, geometry.latitudeE6).map { [$0, $1] },
                digest: geometry.digest
            ),
            travelMode: "cycling",
            routeSource: routeSource
        )
    }

    /// Maps a validated service answer to what the rider sees.
    static func state(
        for response: RouteElevationServiceResponseV1,
        geometry: RouteElevationGeometryV1
    ) -> RouteElevationStateV1 {
        if response.status == "ready", let profile = response.profile {
            guard (try? profile.validate(
                expectedDigest: geometry.digest, expectedPointCount: geometry.pointCount
            )) != nil else { return .unavailable(.serviceUnavailable) }
            return profile.isAvailable ? .ready(profile) : .unavailable(.noCoverage)
        }
        let reasons = Set(response.attempts.compactMap(\.reason))
        if !reasons.isDisjoint(with: ["quota-exhausted", "provider-rate-limited"]) {
            return .unavailable(.rateLimited(retryAfterSeconds: response.retryAfterSeconds))
        }
        if response.attempts.contains(where: { $0.coverage != nil }) || reasons.contains("dem-no-staged-coverage") {
            return .unavailable(.noCoverage)
        }
        return .unavailable(.serviceUnavailable)
    }

    static func state(for error: RouteElevationClientError) -> RouteElevationStateV1 {
        switch error {
        case .offline: .unavailable(.offline)
        case .rateLimited(let seconds): .unavailable(.rateLimited(retryAfterSeconds: seconds))
        case .rejected: .unavailable(.routeNotSupported)
        case .invalidResponse, .cancelled, .unavailable: .unavailable(.serviceUnavailable)
        }
    }

    /// Delay before navigation asks again on its own; slightly longer than the
    /// failure memo so the next attempt really reaches the service.
    static func automaticRetryDelay(for reason: RouteElevationUnavailableReasonV1) -> TimeInterval? {
        switch reason {
        case .offline: 31
        case .serviceUnavailable: 121
        case .rateLimited(let seconds): TimeInterval(min(max(seconds ?? 900, 60), 3_600) + 1)
        case .noCoverage, .routeNotSupported, .sourceNotPermitted: nil
        }
    }

    /// How long a failure is reused before the service is asked again.
    static func retryDelay(for state: RouteElevationStateV1, error: RouteElevationClientError?) -> TimeInterval? {
        guard case .unavailable(let reason) = state else { return nil }
        if case .cancelled? = error { return nil }
        switch reason {
        case .offline: return 30
        case .serviceUnavailable:
            if case .unavailable(let seconds?)? = error { return TimeInterval(min(max(seconds, 30), 3_600)) }
            return 120
        case .rateLimited(let seconds): return TimeInterval(min(max(seconds ?? 900, 60), 86_400))
        case .noCoverage: return 6 * 3_600
        case .routeNotSupported, .sourceNotPermitted: return nil
        }
    }
}

/// Resolves one canonical profile per route: trusted GPX heights first, then
/// a profile cached with the saved archive, then the managed service when the
/// provider policy allows sending the geometry. Navigation never waits on it.
@MainActor
final class RouteElevationService {
    static let memoryCacheLimit = 8

    private let fetcher: RouteElevationProfileFetching?
    private weak var sidecars: RouteElevationSidecarProviding?
    private let now: () -> Date
    private var profiles: [String: RouteElevationProfileV1] = [:]
    private var recency: [String] = []
    private var subjectDigests: [String: String] = [:]
    private var failures: [String: (state: RouteElevationStateV1, until: Date)] = [:]
    private var inFlight: [String: Task<RouteElevationStateV1, Never>] = [:]

    init(
        fetcher: RouteElevationProfileFetching?,
        sidecars: RouteElevationSidecarProviding?,
        now: @escaping () -> Date = Date.init
    ) {
        self.fetcher = fetcher
        self.sidecars = sidecars
        self.now = now
    }

    /// The last ready profile for this exact subject, for immediate display.
    func cachedState(for subject: RouteElevationSubjectV1) -> RouteElevationStateV1? {
        guard let digest = subjectDigests[subject.cacheKey], let profile = profiles[digest] else { return nil }
        return .ready(profile)
    }

    func subject(for binding: RouteElevationArchiveBindingV1) -> RouteElevationSubjectV1? {
        sidecars?.elevationSubject(for: binding)
    }

    func resolve(_ subject: RouteElevationSubjectV1, retry: Bool = false) async -> RouteElevationStateV1 {
        let sidecar = subject.binding.flatMap { sidecars?.elevationSidecar(for: $0) }
        let points = subject.route.points
        let heights = sidecar?.gpxVertexElevations ?? subject.gpxVertexElevations
        let maximumPoints = NavigationRouteLimitsV1.production.maximumPoints
        guard let prepared = await Task.detached(priority: .userInitiated, operation: {
            RouteElevationPreparationV1.prepare(
                points: points, maximumPoints: maximumPoints, gpxVertexElevations: heights
            )
        }).value else {
            return .unavailable(.routeNotSupported)
        }
        let geometry = prepared.geometry
        let digest = geometry.digest
        subjectDigests[subject.cacheKey] = digest
        if let cached = profiles[digest] {
            remember(cached)
            return .ready(cached)
        }
        if let local = prepared.localProfile {
            remember(local)
            return .ready(local)
        }
        if let stored = sidecar?.serviceProfile, sidecar?.geometryDigest == digest,
           (try? stored.validate(expectedDigest: digest, expectedPointCount: geometry.pointCount)) != nil,
           stored.isAvailable {
            remember(stored)
            return .ready(stored)
        }
        guard let routeSource = RouteProviderPolicyV1.routeElevationServiceSource(subject.route.provider) else {
            return .unavailable(.sourceNotPermitted)
        }
        guard geometry.pointCount <= RouteElevationContractV1.maximumRoutePoints else {
            return .unavailable(.routeNotSupported)
        }
        guard let fetcher else { return .unavailable(.serviceUnavailable) }
        if let failure = failures[digest], failure.until > now() {
            let respectsRetryAfter: Bool
            if case .unavailable(.rateLimited) = failure.state { respectsRetryAfter = true } else { respectsRetryAfter = false }
            if !retry || respectsRetryAfter { return failure.state }
        }
        let task: Task<RouteElevationStateV1, Never>
        if let existing = inFlight[digest] {
            task = existing
        } else {
            let request = RouteElevationPreparationV1.request(
                for: geometry, requestID: UUID(), routeSource: routeSource
            )
            task = Task { @MainActor [weak self] in
                let state: RouteElevationStateV1
                var failure: RouteElevationClientError?
                do {
                    let response = try await fetcher.fetchProfile(request)
                    state = RouteElevationPreparationV1.state(for: response, geometry: geometry)
                } catch {
                    let mapped = RouteElevationClientError.classify(error)
                    failure = mapped
                    state = RouteElevationPreparationV1.state(for: mapped)
                }
                self?.finish(digest: digest, state: state, error: failure)
                return state
            }
            inFlight[digest] = task
        }
        let state = await task.value
        if case .ready(let profile) = state, let binding = subject.binding {
            sidecars?.storeElevationProfile(profile, for: binding)
        }
        return state
    }

    private func finish(digest: String, state: RouteElevationStateV1, error: RouteElevationClientError?) {
        inFlight[digest] = nil
        if case .ready(let profile) = state {
            failures[digest] = nil
            remember(profile)
        } else if let delay = RouteElevationPreparationV1.retryDelay(for: state, error: error) {
            failures[digest] = (state, now().addingTimeInterval(delay))
        }
    }

    private func remember(_ profile: RouteElevationProfileV1) {
        let digest = profile.geometry.digest
        profiles[digest] = profile
        recency.removeAll { $0 == digest }
        recency.append(digest)
        while recency.count > Self.memoryCacheLimit {
            profiles[recency.removeFirst()] = nil
        }
    }
}
