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
    private let serviceSession: BicinoServiceSession
    private let execute: BicycleDetourHTTPRequestExecutor

    init(
        serviceSession: BicinoServiceSession,
        execute: BicycleDetourHTTPRequestExecutor? = nil
    ) {
        self.serviceSession = serviceSession
        self.execute = execute ?? { request in
            try await serviceSession.urlSession.data(for: request)
        }
    }

    func post(_ body: BicycleDetourServiceRequestV1) async throws -> BicycleDetourHTTPResponseV1 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try encoder.encode(body)
        var response = try await send(payload, refreshCredential: false)
        if response.statusCode == 401 {
            response = try await send(payload, refreshCredential: true)
        }
        return response
    }

    private func send(_ payload: Data, refreshCredential: Bool) async throws -> BicycleDetourHTTPResponseV1 {
        var request = try await serviceSession.authenticatedRequest(
            path: BicycleDetourServiceContractV1.path,
            method: "POST",
            refreshCredential: refreshCredential
        )
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, urlResponse) = try await execute(request)
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
            throw URLError(.badServerResponse)
        }
#if DEBUG
        print("DETOUR_EVIDENCE service status=\(http.statusCode) refresh=\(refreshCredential) host=\(responseComponents.host ?? "") bytes=\(data.count)")
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
