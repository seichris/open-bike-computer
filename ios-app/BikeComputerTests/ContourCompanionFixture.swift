import Foundation

// Signed target-5 maps and the iPhone contour companion produced by the real
// backend pipeline (map-platform/backend/tests/contour_companion_fixture.py).

private func fixtureFailure(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    Foundation.exit(1)
}

struct ContourFixture {
    let values: [String: String]

    static func load() -> ContourFixture {
        let url = URL(
            fileURLWithPath: "map-platform/backend/tests/fixtures/map_contour_companion_v1.txt"
        )
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            fixtureFailure("contour companion fixture is readable")
        }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            values[String(parts[0])] = String(parts[1])
        }
        return ContourFixture(values: values)
    }

    func string(_ key: String) -> String {
        guard let value = values[key] else { fixtureFailure("fixture has \(key)") }
        return value
    }

    func bytes(_ key: String) -> Data {
        let hex = Array(string(key).utf8)
        var data = Data(capacity: hex.count / 2)
        var index = 0
        while index < hex.count {
            guard let byte = UInt8(String(decoding: hex[index..<index + 2], as: UTF8.self), radix: 16) else {
                fixtureFailure("fixture \(key) is hex")
            }
            data.append(byte)
            index += 2
        }
        return data
    }

    func json<T: Decodable>(_ key: String, as type: T.Type) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(string(key).utf8))
        } catch {
            fixtureFailure("fixture \(key) decodes: \(error)")
        }
    }

    var trustStore: BikeMapStreamTrustStore {
        BikeMapStreamTrustStore(publicKeysByID: [
            string("signature_key_id"): bytes("public_key_x963_hex"),
        ])
    }

    func artifacts(_ variant: String) -> [OfflineMapArtifact] {
        json("\(variant)_artifacts_json", as: [OfflineMapArtifact].self)
    }

    func stream(_ variant: String) -> OfflineMapArtifact {
        artifacts(variant).first(where: \.isBikeMapStream)!
    }

    func companion(_ variant: String) -> OfflineMapArtifact? {
        artifacts(variant).first(where: \.isTopographyCompanion)
    }

    /// Every exact artifact is served by its digest, as the durable
    /// downloader identifies tasks.
    func payloads() -> [String: Data] {
        var result: [String: Data] = [:]
        for variant in ["combined", "plain"] {
            result[stream(variant).sha256] = bytes("\(variant)_stream_hex")
        }
        result[companion("combined")!.sha256] = bytes("combined_companion_hex")
        result[restampedStream.sha256] = bytes("combined_restamped_stream_hex")
        return result
    }

    var restampedStream: OfflineMapArtifact {
        json("combined_restamped_stream_json", as: OfflineMapArtifact.self)
    }

    func catalogMap(_ variant: String) -> OfflineMapCatalogMap {
        let publication = try! JSONSerialization.jsonObject(
            with: Data(string("\(variant)_publication_json").utf8)
        ) as! [String: Any]
        let map: [String: Any] = [
            "mapEntryId": publication["mapEntryId"]!,
            "mapId": publication["legacyMapId"]!,
            "contentReceipt": publication["contentReceipt"]!,
            "alias": publication["canonicalName"]!,
            "aliasSource": "generated",
            "aliasRevision": 1,
            "canonicalName": publication["canonicalName"]!,
            "originChannel": publication["originChannel"]!,
            "sourceRegionName": publication["sourceRegionName"]!,
            "bounds": publication["bounds"]!,
            "renderer": publication["renderer"]!,
            "rendererFormatVersion": publication["rendererFormatVersion"]!,
            "features": publication["features"]!,
            "deliveryState": publication["deliveryState"]!,
            "generatedAt": publication["generatedAt"]!,
            "addedAt": "2026-10-26T00:00:00Z",
            "updatedAt": "2026-10-26T00:00:00Z",
            "artifacts": publication["artifacts"]!,
        ]
        return try! JSONDecoder().decode(
            OfflineMapCatalogMap.self,
            from: JSONSerialization.data(withJSONObject: map)
        )
    }
}
