import Foundation

@MainActor
final class BicinoSocialClient {
    let session: BicinoUserSession
    let urlSession: URLSession
    let baseURL: URL?

    init(session: BicinoUserSession) {
        self.session = session
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        urlSession = URLSession(configuration: configuration, delegate: SocialRedirectPolicy(), delegateQueue: nil)
        baseURL = URL(string: OfflineMapServiceConfig.defaultServerURLString)?.appendingPathComponent("v1/social")
    }

    func request(_ path: String, method: String = "GET", body: Data? = nil,
                 contentType: String = "application/json", query: [URLQueryItem] = []) async throws -> Data {
        guard let baseURL, baseURL.scheme == "https", !path.contains(".."), !path.contains(":") else {
            throw SocialFailure.unavailable
        }
        let expected = session.generation
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw SocialFailure.invalidResponse }
        let key = UUID().uuidString
        for attempt in 0...1 {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(try await session.token(forceRefresh: attempt == 1))", forHTTPHeaderField: "Authorization")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
            let (data, response) = try await urlSession.data(for: request)
            guard expected == session.generation else { throw SocialFailure.accountChanged }
            guard let http = response as? HTTPURLResponse, data.count <= 16 * 1024 * 1024 else {
                throw SocialFailure.invalidResponse
            }
            if http.statusCode == 401 && attempt == 0 { continue }
            guard (200..<300).contains(http.statusCode) else {
                let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
                throw SocialFailure.server(code ?? "service_unavailable")
            }
            return data
        }
        throw SocialFailure.signedOut
    }

    func json(_ path: String, method: String = "GET", body: [String: Any]? = nil,
              query: [URLQueryItem] = []) async throws -> [String: Any] {
        let encoded = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let data = try await request(path, method: method, body: encoded, query: query)
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SocialFailure.invalidResponse
        }
        return value
    }

    func socket(rideID: String) async throws -> URLSessionWebSocketTask {
        guard let baseURL else { throw SocialFailure.unavailable }
        var components = URLComponents(url: baseURL.appendingPathComponent("group-rides/\(rideID)/live"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await session.token())", forHTTPHeaderField: "Authorization")
        return urlSession.webSocketTask(with: request)
    }
}

private final class SocialRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a person token to an object store, provider, or other origin.
        completionHandler(nil)
    }
}
