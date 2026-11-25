import Foundation

typealias BicycleDetourHTTPRequestExecutor = @MainActor (
    URLRequest
) async throws -> (Data, URLResponse)

/// Installation-authenticated transport for `POST /v1/bicycle-detours`. It
/// sends exactly the rider position and one rejoin point; the shared decoder
/// validates the answer. Used for the iPhone's own rides and for the Valhalla
/// leg of Watch-owned rides relayed through this iPhone.
@MainActor
final class BicycleDetourClient: BicycleDetourServiceTransporting {
    private let poster: BicinoServiceJSONPoster

    init(
        serviceSession: BicinoServiceSession,
        execute: BicycleDetourHTTPRequestExecutor? = nil
    ) {
        poster = BicinoServiceJSONPoster(serviceSession: serviceSession, execute: execute)
    }

    func post(_ body: BicycleDetourServiceRequestV1) async throws -> BicycleDetourHTTPResponseV1 {
        try await poster.post(body, path: BicycleDetourServiceContractV1.path, evidenceTag: "DETOUR_EVIDENCE")
    }
}

/// Installation-authenticated transport for `POST /v1/bicycle-routes`: one
/// Create a Route leg's two end points, its profile and the locale.
@MainActor
final class BicycleRouteClient: BicycleRouteServiceTransporting {
    private let poster: BicinoServiceJSONPoster

    init(
        serviceSession: BicinoServiceSession,
        execute: BicycleDetourHTTPRequestExecutor? = nil
    ) {
        poster = BicinoServiceJSONPoster(serviceSession: serviceSession, execute: execute)
    }

    func post(_ body: BicycleRouteServiceRequestV1) async throws -> BicycleDetourHTTPResponseV1 {
        try await poster.post(body, path: BicycleRouteServiceContractV1.path, evidenceTag: "BICYCLE_ROUTE_EVIDENCE")
    }
}

/// Posts a JSON body to the managed Bicino service with the installation
/// credential, refreshing it once on 401, and accepts the answer only from
/// that same service origin.
@MainActor
struct BicinoServiceJSONPoster {
    let serviceSession: BicinoServiceSession
    private let execute: BicycleDetourHTTPRequestExecutor

    init(serviceSession: BicinoServiceSession, execute: BicycleDetourHTTPRequestExecutor?) {
        self.serviceSession = serviceSession
        self.execute = execute ?? { request in
            try await serviceSession.urlSession.data(for: request)
        }
    }

    func post<Body: Encodable>(
        _ body: Body,
        path: String,
        evidenceTag: String
    ) async throws -> BicycleDetourHTTPResponseV1 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(body)
        var response = try await send(payload, path: path, refreshCredential: false, evidenceTag: evidenceTag)
        if response.statusCode == 401 {
            response = try await send(payload, path: path, refreshCredential: true, evidenceTag: evidenceTag)
        }
        return response
    }

    private func send(
        _ payload: Data,
        path: String,
        refreshCredential: Bool,
        evidenceTag: String
    ) async throws -> BicycleDetourHTTPResponseV1 {
        var request = try await serviceSession.authenticatedRequest(
            path: path,
            method: "POST",
            refreshCredential: refreshCredential
        )
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, urlResponse) = try await serviceSession.performRouteRequest(request, execute: execute)
        guard let http = urlResponse as? HTTPURLResponse,
              let responseURL = http.url,
              let serviceURL = request.url,
              let responseComponents = URLComponents(url: responseURL, resolvingAgainstBaseURL: false),
              let serviceComponents = URLComponents(url: serviceURL, resolvingAgainstBaseURL: false),
              responseComponents.scheme == serviceComponents.scheme,
              responseComponents.host == serviceComponents.host,
              responseComponents.port == serviceComponents.port,
              responseComponents.user == nil,
              responseComponents.password == nil else {
            throw URLError(.badServerResponse)
        }
#if DEBUG
        print("\(evidenceTag) service status=\(http.statusCode) refresh=\(refreshCredential) host=\(responseComponents.host ?? "") bytes=\(data.count)")
#endif
        return BicycleDetourHTTPResponseV1(
            statusCode: http.statusCode,
            cacheControl: http.value(forHTTPHeaderField: "Cache-Control"),
            contentType: http.value(forHTTPHeaderField: "Content-Type"),
            retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
            body: data
        )
    }
}
