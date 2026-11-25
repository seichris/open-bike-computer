//
//  OfflineMapServiceConfig.swift
//  BikeComputer
//
//  Build-channel offline map service configuration.
//

import Foundation
import Network

enum OfflineMapServiceConfig {
    nonisolated static let developmentServerURLString = "https://maps-dev.8o.vc"
    nonisolated static let developmentProxyURLString = "https://api-dev.bicino.com"
    nonisolated static let productionServerURLString = "https://maps.8o.vc"
    nonisolated static let unconfiguredServerURLString = "https://invalid.invalid"
    nonisolated static let infoDictionaryHostKey = "BicinoMapServiceHost"
    nonisolated static let lanQualificationOriginDefaultsKey =
        "offlineMap.qualificationOrigin"

    // Only the Debug service-session opt-in consumes this validator. It does
    // not make a custom origin managed or change production host selection.
    nonisolated static func isMatchingLANQualificationOrigin(
        _ serverURLString: String,
        configuredOrigin: String?
    ) -> Bool {
        func origin(_ raw: String?) -> String? {
            guard let raw,
                  let value = URLComponents(string: raw),
                  let scheme = value.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = value.host?.lowercased(),
                  host.range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.local$",
                             options: .regularExpression) != nil,
                  let port = value.port, (1...65535).contains(port),
                  value.user == nil, value.password == nil,
                  value.path.isEmpty || value.path == "/",
                  value.query == nil, value.fragment == nil else { return nil }
            return "\(scheme)://\(host):\(port)"
        }
        guard let selected = origin(configuredOrigin) else { return false }
        return origin(serverURLString) == selected
    }

    nonisolated static let defaultServerURLString = serverURLString(
        infoDictionary: Bundle.main.infoDictionary ?? [:]
    )

    nonisolated static func serverURLString(
        infoDictionary: [String: Any]
    ) -> String {
        guard let configuredHost = infoDictionary[infoDictionaryHostKey] as? String else {
#if HOST_TESTING
            return productionServerURLString
#else
            return unconfiguredServerURLString
#endif
        }
        let host = configuredHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch host {
        case "maps-dev.8o.vc":
            return developmentServerURLString
        case "maps.8o.vc":
            return productionServerURLString
        default:
            // The managed endpoint is build-owned. Fail closed to an
            // unreachable sentinel instead of accepting an arbitrary host or
            // silently crossing from Development into Production.
            return unconfiguredServerURLString
        }
    }
}

/// Development requests select a healthy transport before sending credentials
/// or submitting work. Each service keeps its own result for the current path.
@MainActor
final class BicinoDevelopmentEndpointSelector {
    nonisolated enum Service: Hashable, Sendable {
        case api, catalog

        var direct: URL {
            switch self {
            case .api: URL(string: OfflineMapServiceConfig.developmentServerURLString)!
            case .catalog: URL(string: "https://\(OfflineMapCatalogConfig.productionHost)")!
            }
        }

        var proxy: URL {
            switch self {
            case .api: URL(string: OfflineMapServiceConfig.developmentProxyURLString)!
            case .catalog: URL(string: "https://\(OfflineMapCatalogConfig.developmentProxyHost)")!
            }
        }

        var healthChannel: (key: String, value: String) {
            switch self {
            case .api: ("deploymentChannel", "development")
            case .catalog: ("environment", "production")
            }
        }
    }

    typealias Probe = @Sendable (Service, URL, TimeInterval) async -> Bool

    static let shared = BicinoDevelopmentEndpointSelector()

    private let probe: Probe
    private let monitor: NWPathMonitor?
    private var selected: [Service: URL] = [:]
    private var pending: [Service: Task<URL?, Never>] = [:]
    private var pathGeneration = 0

    init(monitorNetwork: Bool = true, probe: @escaping Probe = probeHealth) {
        self.probe = probe
        let monitor = monitorNetwork ? NWPathMonitor() : nil
        self.monitor = monitor
        monitor?.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in self?.networkDidChange() }
        }
        monitor?.start(queue: DispatchQueue(label: "BicinoDevelopmentEndpointSelector"))
    }

    deinit {
        monitor?.cancel()
    }

    func endpoint(for service: Service) async throws -> URL {
        while true {
            try Task.checkCancellation()
            if let url = selected[service] { return url }
            let generation = pathGeneration
            let task: Task<URL?, Never>
            if let inFlight = pending[service] {
                task = inFlight
            } else {
                task = Task { [probe] in
                    if await probe(service, service.direct, 2.5) { return service.direct }
                    guard !Task.isCancelled else { return nil }
                    if await probe(service, service.proxy, 10) { return service.proxy }
                    return nil
                }
                pending[service] = task
            }
            let result = await task.value
            guard pathGeneration == generation else { continue }
            // A waiter may resume after a newer probe has already started.
            if let url = result { selected[service] = url }
            if pending[service] == task { pending[service] = nil }
            try Task.checkCancellation()
            guard let result else { throw URLError(.cannotConnectToHost) }
            return result
        }
    }

    func networkDidChange() {
        pathGeneration += 1
        for task in pending.values { task.cancel() }
        pending.removeAll()
        selected.removeAll()
    }

    private nonisolated static func probeHealth(
        service: Service, origin: URL, timeout: TimeInterval
    ) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let url = origin.appendingPathComponent("healthz")
        do {
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  response.url == url,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            let channel = service.healthChannel
            return body["status"] as? String == "ok" && body[channel.key] as? String == channel.value
        } catch {
            return false
        }
    }
}
