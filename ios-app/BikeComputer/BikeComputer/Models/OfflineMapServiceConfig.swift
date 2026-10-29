//
//  OfflineMapServiceConfig.swift
//  BikeComputer
//
//  Build-channel offline map service configuration.
//

import Foundation

enum OfflineMapServiceConfig {
    nonisolated static let developmentServerURLString = "https://maps-dev.8o.vc"
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
