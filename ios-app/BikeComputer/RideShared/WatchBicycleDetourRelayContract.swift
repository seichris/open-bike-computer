import Foundation

/// Watch → iPhone relay for the Valhalla leg of a Watch-owned saved-route
/// detour. The Watch has no Bicino credential; the reachable paired iPhone
/// sends the same two-point request with its own App Attest-enrolled
/// installation and returns the HTTP answer unchanged. Messages travel over
/// `WCSession.sendMessageData` and start with a 4-byte tag so the phone can
/// tell them from other message data.
nonisolated enum WatchBicycleDetourRelayV1 {
    static let requestTag = Data("BDR1".utf8)
    static let responseTag = Data("BDS1".utf8)
    static let maximumMessageBytes = BicycleDetourServiceContractV1.maximumResponseBytes + 1_024

    nonisolated struct Response: Codable, Equatable, Sendable {
        let statusCode: Int
        let cacheControl: String?
        let contentType: String?
        let retryAfter: String?
        let body: Data
        /// Set when the iPhone could not reach the service at all.
        let transportFailure: String?
    }

    static func isRequest(_ data: Data) -> Bool {
        data.count > requestTag.count && data.prefix(requestTag.count) == requestTag
    }

    static func encode(_ request: BicycleDetourServiceRequestV1) throws -> Data {
        requestTag + (try JSONEncoder().encode(request))
    }

    /// Decodes and re-validates a relayed request: the phone forwards only a
    /// well-formed two-point request.
    static func decodeRequest(_ data: Data) -> BicycleDetourServiceRequestV1? {
        guard isRequest(data), data.count <= 16 * 1_024,
              let request = try? JSONDecoder().decode(
                BicycleDetourServiceRequestV1.self, from: data.dropFirst(requestTag.count)
              ),
              request.schema == BicycleDetourServiceContractV1.requestSchema,
              ["gpx", "strava", "mapkit"].contains(request.routeSource) else { return nil }
        return request
    }

    static func encode(_ response: Response) -> Data {
        responseTag + ((try? JSONEncoder().encode(response)) ?? Data())
    }

    static func decodeResponse(_ data: Data) -> Response? {
        guard data.count > responseTag.count, data.count <= maximumMessageBytes,
              data.prefix(responseTag.count) == responseTag else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data.dropFirst(responseTag.count))
    }

    static func response(_ http: BicycleDetourHTTPResponseV1) -> Response {
        Response(statusCode: http.statusCode, cacheControl: http.cacheControl, contentType: http.contentType,
                 retryAfter: http.retryAfter, body: http.body, transportFailure: nil)
    }

    static func failure(offline: Bool) -> Response {
        Response(statusCode: 0, cacheControl: nil, contentType: nil, retryAfter: nil, body: Data(),
                 transportFailure: offline ? "offline" : "unavailable")
    }
}

/// The Watch's detour service transport: the paired iPhone's relay.
@MainActor
final class WatchBicycleDetourRelayTransport: BicycleDetourServiceTransporting {
    private let send: @MainActor (Data) async throws -> Data

    init(send: @escaping @MainActor (Data) async throws -> Data) {
        self.send = send
    }

    func post(_ request: BicycleDetourServiceRequestV1) async throws -> BicycleDetourHTTPResponseV1 {
        let reply = try await send(try WatchBicycleDetourRelayV1.encode(request))
        guard let response = WatchBicycleDetourRelayV1.decodeResponse(reply) else {
            throw URLError(.badServerResponse)
        }
        if let failure = response.transportFailure {
            throw URLError(failure == "offline" ? .notConnectedToInternet : .badServerResponse)
        }
        return BicycleDetourHTTPResponseV1(
            statusCode: response.statusCode, cacheControl: response.cacheControl,
            contentType: response.contentType, retryAfter: response.retryAfter, body: response.body
        )
    }
}
