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
