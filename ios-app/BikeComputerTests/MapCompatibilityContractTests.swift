import CryptoKit
import Foundation

// Durable map contract v1 on the iPhone. The frozen corpus was produced once by
// the real backend packaging, promotion and signing code
// (map-platform/backend/tests/map_compatibility_fixture.py); later app builds
// must keep validating and installing those exact bytes.

private let corpusDirectory = "map-platform/backend/tests/fixtures/map-compatibility-v1/"

private func corpusFailure(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    Foundation.exit(1)
}

private struct CorpusVariant {
    let file: String
    let deliveryTier: String
    let publication: [String: Any]

    var url: URL { URL(fileURLWithPath: corpusDirectory + file) }

    var streamArtifact: [String: Any] {
        guard let artifacts = publication["artifacts"] as? [[String: Any]],
              let stream = artifacts.first(where: {
                  $0["format"] as? String == OfflineMapArtifact.bikeMapStreamFormat
              }) else {
            corpusFailure("\(file) publication has one stream")
        }
        return stream
    }

    var platformArtifact: OfflineMapArtifact { catalogArtifact(streamArtifact).platformArtifact }
}

private struct CorpusMap {
    let profile: String
    let mapID: String
    let rendererFormatVersion: Int
    let features: [String]
    let companionFile: String?
    let development: CorpusVariant
    let production: [String: CorpusVariant]

    var variants: [CorpusVariant] { [development] + production.keys.sorted().compactMap { production[$0] } }
}

private struct Corpus {
    let maps: [CorpusMap]
    let publicKeys: [String: Data]
    let channels: [String: String]

    static func load() -> Corpus {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: corpusDirectory + "corpus.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["contract"] as? Int == 1,
              let signers = root["signers"] as? [[String: Any]],
              let maps = root["maps"] as? [[String: Any]] else {
            corpusFailure("map compatibility corpus is readable")
        }
        var publicKeys: [String: Data] = [:]
        var channels: [String: String] = [:]
        for signer in signers {
            guard let keyID = signer["keyId"] as? String,
                  let hex = signer["publicKeyX963Hex"] as? String,
                  let key = Data(ownershipHex: hex),
                  let channel = signer["channel"] as? String else {
                corpusFailure("corpus signer decodes")
            }
            publicKeys[keyID] = key
            channels[keyID] = channel
        }
        func variant(_ value: Any?) -> CorpusVariant {
            guard let value = value as? [String: Any],
                  let file = value["file"] as? String,
                  let tier = value["deliveryTier"] as? String,
                  let publication = value["publication"] as? [String: Any] else {
                corpusFailure("corpus variant decodes")
            }
            return CorpusVariant(file: file, deliveryTier: tier, publication: publication)
        }
        return Corpus(
            maps: maps.map { entry in
                guard let profile = entry["profile"] as? String,
                      let mapID = entry["mapId"] as? String,
                      let format = entry["rendererFormatVersion"] as? Int,
                      let features = entry["features"] as? [String],
                      let production = entry["production"] as? [[String: Any]] else {
                    corpusFailure("corpus map decodes")
                }
                return CorpusMap(
                    profile: profile,
                    mapID: mapID,
                    rendererFormatVersion: format,
                    features: features,
                    companionFile: entry["companionFile"] as? String,
                    development: variant(entry["development"]),
                    production: Dictionary(uniqueKeysWithValues: production.map {
                        ($0["variant"] as? String ?? "", variant($0))
                    })
                )
            },
            publicKeys: publicKeys,
            channels: channels
        )
    }

    func map(_ profile: String) -> CorpusMap {
        guard let map = maps.first(where: { $0.profile == profile }) else {
            corpusFailure("corpus has \(profile)")
        }
        return map
    }

    func trustStore(channels allowed: Set<String>) -> BikeMapStreamTrustStore {
        BikeMapStreamTrustStore(publicKeysByID: publicKeys.filter {
            allowed.contains(channels[$0.key] ?? "")
        })
    }

    /// Bicino keeps only production signers; Bicino Dev adds its own.
    var productionTrust: BikeMapStreamTrustStore { trustStore(channels: ["production"]) }
    var developmentAppTrust: BikeMapStreamTrustStore {
        trustStore(channels: ["production", "development"])
    }
}

private func catalogArtifact(_ value: [String: Any]) -> OfflineMapCatalogArtifact {
    do {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(OfflineMapCatalogArtifact.self, from: data)
    } catch {
        corpusFailure("catalog artifact decodes: \(error)")
    }
}

private func catalogMap(
    _ map: CorpusMap,
    variants: [CorpusVariant],
    deliveryState: String
) -> OfflineMapCatalogMap {
    let publication = map.development.publication
    var value: [String: Any] = [
        "mapEntryId": publication["mapEntryId"] as Any,
        "mapId": map.mapID,
        "contentReceipt": publication["contentReceipt"] as Any,
        "alias": map.profile,
        "aliasSource": "canonical",
        "aliasRevision": 1,
        "canonicalName": publication["canonicalName"] as Any,
        "originChannel": "development",
        "renderer": "esp32-fmb",
        "rendererFormatVersion": map.rendererFormatVersion,
        "features": map.features,
        "deliveryState": deliveryState,
        "addedAt": "2026-10-26T00:00:00Z",
        "updatedAt": "2026-10-26T00:00:00Z",
    ]
    value["artifacts"] = variants.flatMap {
        ($0.publication["artifacts"] as? [[String: Any]] ?? []).filter {
            $0["format"] as? String != "zip-stored-v1"
        }
    }
    do {
        return try JSONDecoder().decode(
            OfflineMapCatalogMap.self,
            from: JSONSerialization.data(withJSONObject: value)
        )
    } catch {
        corpusFailure("catalog map decodes: \(error)")
    }
}

private func readerCapabilityFixture() -> [String: String] {
    guard let text = try? String(
        contentsOf: URL(fileURLWithPath: "protocol/fixtures/map-reader-capabilities-v1.txt"),
        encoding: .utf8
    ) else {
        corpusFailure("map reader capability fixture is readable")
    }
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: " ", maxSplits: 1)
        values[String(parts[0])] = String(parts[1])
    }
    return values
}

/// Authenticated transfer status from a later firmware build than the one any
/// map was delivered with.
private func deviceStatus(
    trust: [String],
    mapReader: String?,
    firmwareBuild: UInt32 = 105
) -> MapTransferDeviceStatus {
    let reader = mapReader.map { ",\"mapReader\":\($0)" } ?? ""
    let trustJSON = trust.map { "\"\($0)\"" }.joined(separator: ",")
    let json = "{\"enabled\":true,\"protocols\":[2],\"streamFormatVersions\":[1]," +
        "\"streamTrust\":[\(trustJSON)],\"firmwareVersion\":\"0.3.5\"," +
        "\"firmwareBuild\":\(firmwareBuild),\"firmwareGitSha\":\"\(String(repeating: "5", count: 40))\"" +
        reader + "}"
    do {
        return try JSONDecoder().decode(MapTransferDeviceStatus.self, from: Data(json.utf8))
    } catch {
        corpusFailure("device status decodes: \(error)")
    }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

enum MapCompatibilityContractTests {
    static func run() {
        let corpus = Corpus.load()
        testFrozenCorpusStillValidates(corpus)
        testThisAppReadsEveryContractProfile(corpus)
        testDurableInstallUsesDeviceReaderCapabilities(corpus)
        testCatalogEligibilityForBothApps(corpus)
        testSavedDurableMapReopensAfterAppUpdate(corpus)
        testPreBaselineMapsAreMarkedWithoutCoercion(corpus)
        testUnsupportedAndCorruptInputsAreRejected(corpus)
    }

    fileprivate static func testFrozenCorpusStillValidates(_ corpus: Corpus) {
        for map in corpus.maps {
            for variant in map.variants {
                let trust = variant.deliveryTier == "production"
                    ? corpus.productionTrust : corpus.developmentAppTrust
                let catalog = catalogArtifact(variant.streamArtifact)
                guard let direct = try? BikeMapStreamArtifactValidator.validate(
                    url: variant.url,
                    artifact: variant.platformArtifact,
                    expectedMapID: map.mapID,
                    trustStore: trust
                ), let viaCatalog = try? BikeMapStreamArtifactValidator.validate(
                    url: variant.url,
                    artifact: catalog.platformArtifact,
                    expectedMapID: map.mapID,
                    trustStore: trust,
                    readerRequirements: catalog.readerRequirements
                ) else {
                    corpusFailure("\(variant.file) validates on the direct-job and catalog paths")
                }
                // Both delivery paths give the map the same signed meaning.
                assertEqual(direct.compatibilityContract, 1, "\(variant.file) is a durable map")
                assertEqual(viaCatalog.compatibilityContract, 1, "\(variant.file) catalog contract")
                assertEqual(direct.readerRequirements, catalog.readerRequirements,
                            "\(variant.file) derived reader requirements match the catalog")
                assertEqual(viaCatalog.readerRequirements, direct.readerRequirements,
                            "\(variant.file) catalog requirements are verified")
                assertEqual(direct.rendererFormatVersion, map.rendererFormatVersion,
                            "\(variant.file) renderer format")
                assertEqual(direct.topography != nil, map.companionFile != nil,
                            "\(variant.file) signed contours require the companion")
                assertEqual(direct.requiredFirmwareBuild, nil,
                            "\(variant.file) carries no firmware identity")
            }
        }
    }

    fileprivate static func testThisAppReadsEveryContractProfile(_ corpus: Corpus) {
        guard let data = try? Data(contentsOf: URL(
                fileURLWithPath: "map-platform/config/map-compatibility-contract-v1.json"
              )),
              let contract = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = contract["profiles"] as? [[String: Any]],
              !profiles.isEmpty else {
            corpusFailure("map compatibility contract is readable")
        }
        for profile in profiles {
            guard let format = profile["rendererFormatVersion"] as? Int,
                  let features = profile["features"] as? [String],
                  let renderer = profile["renderer"] as? String else {
                corpusFailure("contract profile decodes")
            }
            let requirements = OfflineMapReaderRequirements(
                schemaVersion: 1,
                streamFormat: OfflineMapArtifact.bikeMapStreamFormat,
                manifestSchemaVersion: 1,
                renderer: renderer,
                rendererFormatVersion: format,
                requiredFeatures: features
            )
            // Bicino and Bicino Dev share these readers, so every profile in
            // every channel must stay readable by every later app build.
            assert(OfflineMapReaderCompatibilityPolicy.supports(requirements),
                   "app reads contract profile \(profile["id"] ?? format)")
        }
        assertEqual(Set(corpus.maps.map(\.profile)),
                    Set(profiles.compactMap { $0["id"] as? String }),
                    "frozen corpus covers every contract profile")
    }

    fileprivate static func testDurableInstallUsesDeviceReaderCapabilities(_ corpus: Corpus) {
        let readers = readerCapabilityFixture()
        guard let productionReader = readers["production"], let poiReader = readers["map_pois"] else {
            corpusFailure("reader capability fixture lines exist")
        }
        let productionFirmware = deviceStatus(
            trust: corpus.productionTrust.capabilityHeaderValue?
                .split(separator: ",").map(String.init) ?? [],
            mapReader: productionReader
        )
        let developmentFirmware = deviceStatus(
            trust: corpus.developmentAppTrust.capabilityHeaderValue?
                .split(separator: ",").map(String.init) ?? [],
            mapReader: poiReader
        )
        assert(productionFirmware.mapReader != nil, "firmware reader report decodes")
        for map in corpus.maps {
            for variant in map.variants {
                let trust = variant.deliveryTier == "production"
                    ? corpus.productionTrust : corpus.developmentAppTrust
                guard let verified = try? BikeMapStreamArtifactValidator.validate(
                    url: variant.url, artifact: variant.platformArtifact,
                    expectedMapID: map.mapID, trustStore: trust
                ) else {
                    corpusFailure("\(variant.file) validates")
                }
                let capability = "\(verified.signatureKeyID)=\(verified.signatureKeySHA256)"
                func evaluate(
                    _ status: MapTransferDeviceStatus,
                    contract: Int? = verified.compatibilityContract,
                    reader: OfflineMapReaderCapabilities?? = nil
                ) -> MapInstallProtocolEvaluation {
                    // The saved copy still carries the exact firmware identity an
                    // older controller attached for build 104.
                    MapInstallProtocolSelector.evaluate(
                        isBikeMapStream: true,
                        signatureTrustCapability: capability,
                        readerRequirements: verified.readerRequirements,
                        compatibilityContract: contract,
                        deviceReaderCapabilities: reader ?? status.mapReader,
                        requiredFirmwareVersion: "0.3.4",
                        requiredFirmwareBuild: 104,
                        requiredFirmwareGitSha: String(repeating: "4", count: 40),
                        deviceStatus: status
                    )
                }
                let poi = map.features.contains("map-pois")
                let production = variant.deliveryTier == "production"
                // Development firmware with the POI reader and the dev signer
                // installs every durable map after a firmware update.
                assertEqual(evaluate(developmentFirmware), .streamV2,
                            "\(variant.file) installs on later development firmware")
                if production {
                    assertEqual(evaluate(productionFirmware), .streamV2,
                                "\(variant.file) installs on later production firmware")
                } else {
                    // Stock firmware trusts only production signers.
                    assertEqual(evaluate(productionFirmware).rejection, .signingKeyNotTrusted,
                                "\(variant.file) needs development trust on the bike")
                }
                // An app cannot make firmware read a format it lacks.
                let productionReaderTrustingAll = deviceStatus(
                    trust: corpus.developmentAppTrust.capabilityHeaderValue?
                        .split(separator: ",").map(String.init) ?? [],
                    mapReader: productionReader
                )
                assertEqual(evaluate(productionReaderTrustingAll).rejection,
                            poi ? .deviceReaderUnsupported : nil,
                            "\(variant.file) needs the POI reader exactly when it has POIs")
                // Older firmware without a reader report: renderer feature bits.
                let legacyFeatures = LegacyDeviceRendererFeatures(
                    streetLabels: true, buildings3D: true, contours: true, mapPois: false
                )
                let legacyReader = DeviceMapReaderCapabilityPolicy.capabilities(
                    reported: nil, legacyFeatures: legacyFeatures
                )
                let legacyStatus = deviceStatus(
                    trust: corpus.developmentAppTrust.capabilityHeaderValue?
                        .split(separator: ",").map(String.init) ?? [],
                    mapReader: nil
                )
                assertEqual(evaluate(legacyStatus, reader: .some(legacyReader)).rejection,
                            poi ? .deviceReaderUnsupported : nil,
                            "\(variant.file) on firmware that predates the reader report")
                assertEqual(evaluate(legacyStatus, reader: .some(nil)).rejection,
                            .deviceReaderUnknown,
                            "\(variant.file) needs authenticated reader capabilities")
                // The same bytes without the signed marker are pre-baseline and
                // keep the exact firmware rule; nothing coerces them.
                assertEqual(evaluate(developmentFirmware, contract: nil).rejection,
                            .firmwareIdentityMismatch,
                            "\(variant.file) without a marker keeps the old firmware pin")
            }
        }
        let malformed = deviceStatus(trust: [], mapReader: "{\"schemaVersion\":\"one\"}")
        assertEqual(malformed.mapReader, nil, "malformed reader report falls back")
        assert(malformed.supportsBikeMapStreamV1, "malformed reader report keeps the status")
        let reported = DeviceMapReaderCapabilityPolicy.capabilities(
            reported: productionFirmware.mapReader,
            legacyFeatures: LegacyDeviceRendererFeatures(
                streetLabels: false, buildings3D: false, contours: false, mapPois: true
            )
        )
        assertEqual(reported, productionFirmware.mapReader,
                    "the firmware's own report outranks renderer feature bits")
        assertEqual(
            OfflineMapPlatformError.mapStreamCompatibilityRejected(.firmwareIdentityMismatch)
                .errorDescription?.contains("before durable maps"),
            true,
            "only pre-baseline maps fail on a firmware identity and say so"
        )
    }

    fileprivate static func testCatalogEligibilityForBothApps(_ corpus: Corpus) {
        let buildings = corpus.map("buildings-3d-v1")
        let everyTier = catalogMap(buildings, variants: buildings.variants, deliveryState: "production")
        let productionArtifacts = Set(buildings.production.values.map {
            $0.streamArtifact["sha256"] as? String ?? ""
        })
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: everyTier, channel: "production", trustStore: corpus.productionTrust
            ),
            .available,
            "Bicino downloads approved production artifacts"
        )
        assert(
            !OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: productionArtifacts,
                map: everyTier, channel: "production", trustStore: corpus.productionTrust
            ),
            "a saved production copy stays current after rotation and a worker update"
        )
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: everyTier, channel: "development", trustStore: corpus.developmentAppTrust
            ),
            .available,
            "Bicino Dev downloads the same library map"
        )
        assert(
            !OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [buildings.development.streamArtifact["sha256"] as? String ?? ""],
                map: everyTier, channel: "development", trustStore: corpus.developmentAppTrust
            ),
            "Bicino Dev prefers the development artifact"
        )
        let productionOnly = catalogMap(
            buildings, variants: Array(buildings.production.values), deliveryState: "production"
        )
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: productionOnly, channel: "development", trustStore: corpus.developmentAppTrust
            ),
            .available,
            "Bicino Dev falls back to production artifacts"
        )
        let rotatedOnly = catalogMap(
            buildings,
            variants: [buildings.production["production-rotated-key"]!],
            deliveryState: "production"
        )
        let rotatedTrust = BikeMapStreamTrustStore(publicKeysByID: corpus.publicKeys.filter {
            $0.key == "map-compat-fixture-prod-2"
        })
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: rotatedOnly, channel: "production", trustStore: rotatedTrust
            ),
            .available,
            "a rotated signer the app trusts keeps the map available"
        )
        let pois = corpus.map("map-pois-contours-v1")
        let developmentOnly = catalogMap(pois, variants: [pois.development], deliveryState: "development")
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: developmentOnly, channel: "production", trustStore: corpus.productionTrust
            ),
            .awaitingProductionPromotion,
            "Bicino never consumes a development artifact"
        )
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: developmentOnly, channel: "development", trustStore: corpus.developmentAppTrust
            ),
            .available,
            "Bicino Dev consumes development POI and contour maps"
        )
        assert(
            OfflineMapTopographyCompanionPolicy.compatibleCompanion(
                for: developmentOnly, deliveryTier: "development"
            ) != nil,
            "the development contour companion is selected for its stream"
        )
        let contours = corpus.map("topographic-contours-v1")
        let promotedContours = catalogMap(contours, variants: contours.variants, deliveryState: "production")
        assert(
            OfflineMapTopographyCompanionPolicy.compatibleCompanion(
                for: promotedContours, deliveryTier: "production"
            ) != nil,
            "the promoted contour companion is selected for its production stream"
        )
    }

    fileprivate static func testSavedDurableMapReopensAfterAppUpdate(_ corpus: Corpus) {
        let map = corpus.map("topographic-contours-v1")
        let variant = map.production["production"]!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-compat-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = directory.appendingPathComponent("\(map.mapID).bmap")
        try! FileManager.default.copyItem(at: variant.url, to: saved)
        // Metadata as an earlier app build wrote it: the artifact record still
        // carries an exact firmware identity and no reader fields.
        var artifact = variant.streamArtifact
        artifact["requiredFirmwareVersion"] = "0.3.4"
        artifact["requiredFirmwareBuild"] = 104
        artifact["requiredFirmwareGitSha"] = String(repeating: "4", count: 40)
        artifact.removeValue(forKey: "readerRequirements")
        let metadataJSON: [String: Any] = [
            "schemaVersion": 1,
            "mapID": map.mapID,
            "displayName": "Saved before an app update",
            "localArtifactFilename": saved.lastPathComponent,
            "streamFormatVersion": 1,
            "rendererFormatVersion": map.rendererFormatVersion,
            "primaryArtifact": artifact,
        ]
        try! JSONSerialization.data(withJSONObject: metadataJSON)
            .write(to: SavedMapArtifactMetadataStore.metadataURL(for: saved))
        guard let metadata = SavedMapArtifactMetadataStore.load(for: saved),
              let primary = metadata.primaryArtifact else {
            corpusFailure("earlier saved metadata still loads")
        }
        guard let verified = try? BikeMapStreamArtifactValidator.validate(
            url: saved, artifact: primary, expectedMapID: metadata.mapID,
            trustStore: corpus.productionTrust, readerRequirements: metadata.readerRequirements
        ) else {
            corpusFailure("the saved durable map reopens offline")
        }
        assertEqual(verified.compatibilityContract, 1, "reopened map stays durable")
        assertEqual(verified.requiredFirmwareBuild, 104, "earlier delivery metadata is kept")
        let status = deviceStatus(
            trust: corpus.productionTrust.capabilityHeaderValue?
                .split(separator: ",").map(String.init) ?? [],
            mapReader: readerCapabilityFixture()["production"]
        )
        assertEqual(
            MapInstallProtocolSelector.evaluate(
                isBikeMapStream: true,
                signatureTrustCapability: "\(verified.signatureKeyID)=\(verified.signatureKeySHA256)",
                readerRequirements: verified.readerRequirements,
                compatibilityContract: verified.compatibilityContract,
                deviceReaderCapabilities: status.mapReader,
                requiredFirmwareVersion: verified.requiredFirmwareVersion,
                requiredFirmwareBuild: verified.requiredFirmwareBuild,
                requiredFirmwareGitSha: verified.requiredFirmwareGitSHA,
                deviceStatus: status
            ),
            .streamV2,
            "a firmware update does not strand a saved durable map"
        )
        assert(!SavedMapCompatibilityPolicy.isPreBaseline(packURL: saved),
               "Saved Maps does not mark a durable map")
    }

    fileprivate static func testPreBaselineMapsAreMarkedWithoutCoercion(_ corpus: Corpus) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-pre-baseline-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Real producer output from before the baseline (the contour companion
        // fixture predates the contract marker).
        guard let earlier = try? String(
            contentsOf: URL(fileURLWithPath:
                "map-platform/backend/tests/fixtures/map_contour_companion_v1.txt"),
            encoding: .utf8
        ), let line = earlier.split(separator: "\n").first(where: {
            $0.hasPrefix("combined_stream_hex=")
        }), let earlierStream = Data(ownershipHex: String(line.dropFirst("combined_stream_hex=".count))) else {
            corpusFailure("pre-baseline producer fixture is readable")
        }
        let stream = directory.appendingPathComponent("contour-fixture.bmap")
        try! earlierStream.write(to: stream)
        assert(SavedMapCompatibilityPolicy.isPreBaseline(packURL: stream),
               "a signed stream without a marker is pre-baseline")
        let archive = directory.appendingPathComponent("legacy.zip")
        try! Data("PK".utf8).write(to: archive)
        assert(SavedMapCompatibilityPolicy.isPreBaseline(packURL: archive),
               "an unsigned archive is pre-baseline")
        let unreadable = directory.appendingPathComponent("damaged.bmap")
        try! Data([0x42]).write(to: unreadable)
        assert(!SavedMapCompatibilityPolicy.isPreBaseline(packURL: unreadable),
               "a damaged file reports its own validation error")
        for map in corpus.maps {
            assert(!SavedMapCompatibilityPolicy.isPreBaseline(packURL: map.development.url),
                   "\(map.profile) is not marked pre-baseline")
        }
    }

    fileprivate static func testUnsupportedAndCorruptInputsAreRejected(_ corpus: Corpus) {
        let map = corpus.map("buildings-3d-v1")
        let variant = map.development
        let original = try! Data(contentsOf: variant.url)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("map-compat-negative-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func rejects(_ stream: Data, trust: BikeMapStreamTrustStore,
                     artifact: OfflineMapArtifact? = nil, _ message: String) {
            let url = directory.appendingPathComponent(UUID().uuidString + ".bmap")
            try! stream.write(to: url)
            let candidate = artifact ?? identity(for: stream, like: variant.platformArtifact)
            do {
                _ = try BikeMapStreamArtifactValidator.validate(
                    url: url, artifact: candidate, expectedMapID: map.mapID, trustStore: trust
                )
                corpusFailure(message)
            } catch {}
        }

        rejects(original, trust: corpus.productionTrust, artifact: variant.platformArtifact,
                "Bicino rejects a development-signed map")
        var corrupted = original
        corrupted[corrupted.count - 1] ^= 0x01
        rejects(corrupted, trust: corpus.developmentAppTrust, artifact: variant.platformArtifact,
                "a corrupted payload is rejected")
        rejects(original.dropLast(), trust: corpus.developmentAppTrust,
                "a truncated stream is rejected")
        rejects(original + Data([0]), trust: corpus.developmentAppTrust,
                "trailing bytes are rejected")
        rejects(resigned(original, replacing: "\"contract\":1", with: "\"contract\":0"),
                trust: corpus.developmentAppTrust, "an invalid contract marker is rejected")
        rejects(resigned(original, replacing: "\"formatVersion\":3", with: "\"formatVersion\":9"),
                trust: corpus.developmentAppTrust, "an unknown renderer format is rejected")
        let unknownContract = resigned(original, replacing: "\"contract\":1", with: "\"contract\":2")
        let url = directory.appendingPathComponent("future-contract.bmap")
        try! unknownContract.write(to: url)
        let future = try? BikeMapStreamArtifactValidator.validate(
            url: url, artifact: identity(for: unknownContract, like: variant.platformArtifact),
            expectedMapID: map.mapID, trustStore: corpus.developmentAppTrust
        )
        assertEqual(future?.compatibilityContract, 2,
                    "a later contract stays readable when its reader requirements are")
    }

    /// Re-signs a frozen manifest edit with the development fixture key
    /// (public test scalar 0x4D430001) so only the edited field differs.
    private static func resigned(_ stream: Data, replacing old: String, with new: String) -> Data {
        guard let header = try? BikeMapStreamFormat.parseHeader(stream.prefix(32)) else {
            corpusFailure("stream header parses")
        }
        let manifestStart = 32
        let manifestEnd = manifestStart + Int(header.manifestBytes)
        let envelopeEnd = manifestEnd + Int(header.signatureEnvelopeBytes)
        let manifest = String(decoding: stream[manifestStart..<manifestEnd], as: UTF8.self)
        assert(manifest.contains(old) && old.utf8.count == new.utf8.count,
               "fixture manifest has the edited field")
        let edited = Data(manifest.replacingOccurrences(of: old, with: new).utf8)
        var scalar = Data(repeating: 0, count: 28)
        scalar.append(contentsOf: [0x4D, 0x43, 0x00, 0x01])
        let key = try! P256.Signing.PrivateKey(rawRepresentation: scalar)
        var signature = Array(
            try! key.signature(for: BikeMapStreamFormat.signatureDomain + edited).rawRepresentation
        )
        // Readers accept only canonical low-S signatures: s' = n - s.
        let order = Array(Data(ownershipHex:
            "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")!)
        let half = Array(Data(ownershipHex:
            "7fffffff800000007fffffffffffffffde737d56d38bcf4279dce5617e3192a8")!)
        if half.lexicographicallyPrecedes(signature[32..<64]) {
            var borrow = 0
            for index in stride(from: 31, through: 0, by: -1) {
                let value = Int(order[index]) - Int(signature[32 + index]) - borrow
                signature[32 + index] = UInt8((value + 256) % 256)
                borrow = value < 0 ? 1 : 0
            }
        }
        var envelope = Data(stream[manifestEnd..<envelopeEnd])
        envelope.replaceSubrange(envelope.count - 64..<envelope.count, with: signature)
        return stream.prefix(manifestStart) + edited + envelope + stream[envelopeEnd...]
    }

    /// Artifact metadata that matches edited bytes, so only the signed content
    /// itself can fail validation.
    private static func identity(for stream: Data, like original: OfflineMapArtifact) -> OfflineMapArtifact {
        guard let header = try? BikeMapStreamFormat.parseHeader(stream.prefix(32)),
              stream.count >= 32 + Int(header.manifestBytes) + Int(header.signatureEnvelopeBytes) else {
            return OfflineMapArtifact(
                format: original.format, mediaType: original.mediaType,
                filename: original.filename, objectKey: original.objectKey,
                bytes: Int64(stream.count), sha256: sha256Hex(stream),
                manifestReceipt: original.manifestReceipt,
                signedManifestReceipt: original.signedManifestReceipt,
                signatureKeyId: original.signatureKeyId,
                signatureKeySha256: original.signatureKeySha256,
                producerBuildSha256: original.producerBuildSha256,
                producerImageDigest: original.producerImageDigest
            )
        }
        let manifestEnd = 32 + Int(header.manifestBytes)
        let manifest = stream[32..<manifestEnd]
        let envelope = stream[manifestEnd..<(manifestEnd + Int(header.signatureEnvelopeBytes))]
        let signedReceipt = BikeMapStreamFormat.signedManifestReceipt(
            manifest: Data(manifest), envelope: Data(envelope)
        )
        let prefix = original.objectKey.split(separator: "/").dropLast().joined(separator: "/")
        return OfflineMapArtifact(
            format: original.format, mediaType: original.mediaType,
            filename: original.filename, objectKey: "\(prefix)/\(signedReceipt).bmap",
            bytes: Int64(stream.count), sha256: sha256Hex(stream),
            manifestReceipt: BikeMapStreamFormat.manifestReceipt(Data(manifest)),
            signedManifestReceipt: signedReceipt,
            signatureKeyId: original.signatureKeyId,
            signatureKeySha256: original.signatureKeySha256,
            producerBuildSha256: original.producerBuildSha256,
            producerImageDigest: original.producerImageDigest
        )
    }
}
