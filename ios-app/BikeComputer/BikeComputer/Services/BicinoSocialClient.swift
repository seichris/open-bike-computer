import Foundation

enum SocialFailure: LocalizedError {
    case unavailable, signedOut, cancelled, accountChanged, invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "Social riding is not configured for this build."
        case .signedOut: "Sign in to use social riding."
        case .cancelled: "Sign-in was cancelled."
        case .accountChanged: "Your account changed. Try again."
        case .invalidResponse: "Bicino returned an invalid response."
        case .server(let code): code.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

@MainActor
protocol SocialAuthenticating: AnyObject {
    var generation: UUID { get }
    func token(forceRefresh: Bool) async throws -> String
}

@MainActor
protocol SocialSocket: AnyObject {
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive() async throws -> URLSessionWebSocketTask.Message
}
extension URLSessionWebSocketTask: SocialSocket {}

@MainActor
protocol SocialRideNetworking {
    func request(_ path: String, method: String, body: Data?, contentType: String, query: [URLQueryItem]) async throws -> Data
    func socket(rideID: String) async throws -> any SocialSocket
}

extension SocialRideNetworking {
    func json(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        let encoded = try body.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let data = try await request(path, method: method, body: encoded, contentType: "application/json", query: [])
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SocialFailure.invalidResponse }
        return value
    }
}


@MainActor
final class BicinoSocialClient: SocialRideNetworking {
    let session: any SocialAuthenticating
    let urlSession: URLSession
    let baseURL: URL?

    init(session: any SocialAuthenticating, baseURL: URL?, urlSession: URLSession? = nil) {
        self.session = session
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        self.urlSession = urlSession ?? URLSession(configuration: configuration, delegate: SocialRedirectPolicy(), delegateQueue: nil)
        self.baseURL = baseURL
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
        var refreshed = false, forceRefresh = false, transportRetried = false
        while true {
            guard expected == session.generation else { throw SocialFailure.accountChanged }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(try await session.token(forceRefresh: forceRefresh))", forHTTPHeaderField: "Authorization")
            forceRefresh = false
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "Idempotency-Key")
            let data: Data
            let response: URLResponse
            do { (data, response) = try await urlSession.data(for: request) }
            catch let error as URLError {
                // State packets have their own monotonic delivery contract. Other
                // mutations use this same operation key after an ambiguous loss.
                if !transportRetried, method == "GET" || !path.hasSuffix("/state"),
                   [.timedOut, .networkConnectionLost].contains(error.code) {
                    transportRetried = true
                    continue
                }
                throw error
            }
            guard expected == session.generation else { throw SocialFailure.accountChanged }
            guard let http = response as? HTTPURLResponse, data.count <= 16 * 1024 * 1024 else {
                throw SocialFailure.invalidResponse
            }
            if http.statusCode == 401 && !refreshed {
                refreshed = true; forceRefresh = true; continue
            }
            guard (200..<300).contains(http.statusCode) else {
                let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
                throw SocialFailure.server(code ?? "service_unavailable")
            }
            return data
        }
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

    func socket(rideID: String) async throws -> any SocialSocket {
        guard let baseURL else { throw SocialFailure.unavailable }
        var components = URLComponents(url: baseURL.appendingPathComponent("group-rides/\(rideID)/live"), resolvingAgainstBaseURL: false)!
        components.scheme = "wss"
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await session.token(forceRefresh: false))", forHTTPHeaderField: "Authorization")
        return urlSession.webSocketTask(with: request)
    }

    func deleteAccount(body: [String: Any]) async throws {
        do {
            _ = try await json("me/deletion", method: "POST", body: body)
        } catch SocialFailure.server(let code) where ["account_deleting", "account_deleted"].contains(code) {
            // An accepted deletion can finish before its lost response is retried.
        }
    }
}

private final class SocialRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a person token to an object store, provider, or other origin.
        completionHandler(nil)
    }
}
