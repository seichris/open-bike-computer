import Foundation

typealias RouteElevationHTTPRequestExecutor = @MainActor (
    URLRequest
) async throws -> (Data, URLResponse)

/// Installation-authenticated client for Bicino's route elevation endpoint.
/// Only a route the provider policy admits is ever sent; the response holds
/// distances and heights, never coordinates, and is validated before use.
@MainActor
final class RouteElevationClient: RouteElevationProfileFetching {
    static let path = "/v1/route-elevation-profiles"

    private let serviceSession: BicinoServiceSession
    private let execute: RouteElevationHTTPRequestExecutor

    init(
        serviceSession: BicinoServiceSession,
        execute: RouteElevationHTTPRequestExecutor? = nil
    ) {
        self.serviceSession = serviceSession
        self.execute = execute ?? { request in
            try await serviceSession.urlSession.data(for: request)
        }
    }

    func fetchProfile(
        _ body: RouteElevationServiceRequestV1
    ) async throws -> RouteElevationServiceResponseV1 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let payload = try? encoder.encode(body) else {
            throw RouteElevationClientError.rejected(code: "route_elevation_encoding_failed")
        }
        var response = try await send(payload, refreshCredential: false)
        if response.http.statusCode == 401 {
            response = try await send(payload, refreshCredential: true)
        }
        return try RouteElevationResponseDecoderV1.decode(
            statusCode: response.http.statusCode,
            cacheControl: response.http.value(forHTTPHeaderField: "Cache-Control"),
            contentType: response.http.value(forHTTPHeaderField: "Content-Type"),
            retryAfter: response.http.value(forHTTPHeaderField: "Retry-After"),
            body: response.data
        )
    }

    private struct Response {
        let data: Data
        let http: HTTPURLResponse
    }

    private func send(_ payload: Data, refreshCredential: Bool) async throws -> Response {
        var request: URLRequest
        let data: Data
        let urlResponse: URLResponse
        do {
            request = try await serviceSession.authenticatedRequest(
                path: Self.path,
                method: "POST",
                refreshCredential: refreshCredential
            )
            request.httpBody = payload
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            (data, urlResponse) = try await execute(request)
        } catch {
            throw RouteElevationClientError.classify(error)
        }
        guard let http = urlResponse as? HTTPURLResponse,
              let responseURL = http.url,
              let serviceURL = serviceSession.managedServiceURL,
              let responseComponents = URLComponents(url: responseURL, resolvingAgainstBaseURL: false),
              let serviceComponents = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false),
              responseComponents.scheme == serviceComponents.scheme,
              responseComponents.host == serviceComponents.host,
              responseComponents.port == serviceComponents.port,
              responseComponents.user == nil,
              responseComponents.password == nil else {
            throw RouteElevationClientError.invalidResponse
        }
        return Response(data: data, http: http)
    }
}
