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
    let id: String
    let profile: String
    let optionalLayers: [String]
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
                guard let id = entry["id"] as? String,
                      let profile = entry["profile"] as? String,
                      let optionalLayers = entry["optionalLayers"] as? [String],
                      let mapID = entry["mapId"] as? String,
                      let format = entry["rendererFormatVersion"] as? Int,
                      let features = entry["features"] as? [String],
                      let production = entry["production"] as? [[String: Any]] else {
                    corpusFailure("corpus map decodes")
                }
                return CorpusMap(
                    id: id,
                    profile: profile,
                    optionalLayers: optionalLayers,
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

    func map(_ id: String) -> CorpusMap {
        guard let map = maps.first(where: { $0.id == id }) else {
            corpusFailure("corpus has \(id)")
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

/// A bike's `streamTrust` report for exactly these signers.
private func streamTrust(_ trust: BikeMapStreamTrustStore) -> [String] {
    trust.capabilityHeaderValue?.split(separator: ",").map(String.init) ?? []
}

enum MapCompatibilityContractTests {
    @MainActor
    static func run() {
        let corpus = Corpus.load()
        testFrozenCorpusStillValidates(corpus)
        testThisAppReadsEveryContractProfile(corpus)
        testDurableInstallUsesDeviceReaderCapabilities(corpus)
        testCatalogEligibilityForBothApps(corpus)
        testCatalogSelectionFollowsBikeTrust(corpus)
        testBikeTrustComesFromAuthenticatedStatus(corpus)
        testSavedDurableMapReopensAfterAppUpdate(corpus)
        testMapsOutsideTheContractAreMarkedWithoutCoercion(corpus)
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
                assertEqual(direct.containsTerrain,
                            map.optionalLayers.contains("terrain-experiment-v1"),
                            "\(variant.file) optional terrain layer")
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
                // The app's own renderer pre-check on firmware without the
                // terrain experiment defers a durable map's optional layer to
                // the install check, but blocks the same bytes outside the
                // contract.
                func passesPreCheck(contract: Int?) -> Bool {
                    SavedMapRendererCompatibilityPolicy.isCompatible(
                        rendererFormatVersion: verified.rendererFormatVersion,
                        supportsStreetLabels: true,
                        supports3DBuildings: true,
                        supportsTopographicContours: true,
                        containsTerrain: verified.containsTerrain,
                        supportsTerrainExperiments: false,
                        supportsMapPois: true,
                        includesContours: verified.topography != nil,
                        compatibilityContract: contract
                    )
                }
                assert(passesPreCheck(contract: verified.compatibilityContract),
                       "\(variant.file) passes the app pre-check")
                assertEqual(passesPreCheck(contract: nil), !verified.containsTerrain,
                            "\(variant.file) terrain outside the contract needs the experiment")
                let capability = "\(verified.signatureKeyID)=\(verified.signatureKeySHA256)"
                func evaluate(
                    _ status: MapTransferDeviceStatus,
                    contract: Int? = verified.compatibilityContract,
                    reader: OfflineMapReaderCapabilities?? = nil,
                    terrainExperiments: Bool = false
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
                        containsTerrain: verified.containsTerrain,
                        supportsTerrainExperiments: terrainExperiments,
                        deviceStatus: status
                    )
                }
                let poi = map.features.contains("map-pois")
                let terrain = verified.containsTerrain
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
                // Firmware without the report may predate terrain support
                // (releases before v0.3.4-release.11 refuse terrain files), so
                // the optional layer then needs the terrain experiment.
                assertEqual(evaluate(legacyStatus, reader: .some(legacyReader)).rejection,
                            poi || terrain ? .deviceReaderUnsupported : nil,
                            "\(variant.file) on firmware that predates the reader report")
                assertEqual(
                    evaluate(legacyStatus, reader: .some(legacyReader),
                             terrainExperiments: true).rejection,
                    poi ? .deviceReaderUnsupported : nil,
                    "\(variant.file) on older firmware with the terrain experiment"
                )
                assertEqual(evaluate(legacyStatus, reader: .some(nil)).rejection,
                            .deviceReaderUnknown,
                            "\(variant.file) needs authenticated reader capabilities")
                // The same bytes without the signed marker are outside the
                // contract and keep the exact firmware rule; nothing coerces
                // them.
                assertEqual(evaluate(developmentFirmware, contract: nil,
                                     terrainExperiments: true).rejection,
                            .firmwareIdentityMismatch,
                            "\(variant.file) without a marker keeps the old firmware pin")
                assertEqual(evaluate(developmentFirmware, contract: nil).rejection,
                            terrain ? .deviceReaderUnsupported : .firmwareIdentityMismatch,
                            "\(variant.file) without a marker needs the terrain experiment")
            }
        }
        let malformed = deviceStatus(trust: [], mapReader: "{\"schemaVersion\":\"one\"}")
        assertEqual(malformed.mapReader, nil, "malformed reader report falls back")
        assert(malformed.supportsBikeMapStreamV1, "malformed reader report keeps the status")
        let legacyFeatures = LegacyDeviceRendererFeatures(
            streetLabels: true, buildings3D: true, contours: true, mapPois: false
        )
        let laterSchema = deviceStatus(
            trust: [],
            mapReader: productionReader.replacingOccurrences(
                of: "\"schemaVersion\":1", with: "\"schemaVersion\":2"
            )
        )
        assertEqual(laterSchema.mapReader?.schemaVersion, 2, "later reader report decodes")
        assertEqual(
            DeviceMapReaderCapabilityPolicy.capabilities(
                reported: laterSchema.mapReader, legacyFeatures: legacyFeatures
            ),
            DeviceMapReaderCapabilityPolicy.legacy(legacyFeatures),
            "a later reader report schema falls back to the renderer feature bits"
        )
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
                .errorDescription?.contains("isn't a durable map"),
            true,
            "only maps outside the contract fail on a firmware identity and say so"
        )
    }

    fileprivate static func testCatalogEligibilityForBothApps(_ corpus: Corpus) {
        let buildings = corpus.map("buildings-3d-v1")
        let everyTier = catalogMap(buildings, variants: buildings.variants, deliveryState: "production")
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: everyTier, channel: "production", trustStore: corpus.productionTrust
            ),
            .available,
            "Bicino downloads approved production artifacts"
        )
        // Whichever production copy the library lists after a key rotation or
        // worker update, the map stays available and a saved copy of that
        // head is current. A saved earlier copy may be offered the update, but
        // keeps validating and installing (see the install and reopen tests).
        for name in ["production", "production-rotated-key", "production-updated-worker"] {
            guard let head = buildings.production[name] else {
                corpusFailure("corpus has \(name)")
            }
            let library = catalogMap(
                buildings, variants: [buildings.development, head], deliveryState: "production"
            )
            assertEqual(
                OfflineMapCatalogAvailabilityPolicy.availability(
                    for: library, channel: "production", trustStore: corpus.productionTrust
                ),
                .available,
                "\(name) head keeps the library map available"
            )
            assert(
                !OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                    localArtifactSHA256s: [head.streamArtifact["sha256"] as? String ?? ""],
                    map: library, channel: "production", trustStore: corpus.productionTrust
                ),
                "a saved copy of the \(name) head is current"
            )
        }
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

    /// Bicino Dev trusts both signer sets, but production and ordinary firmware
    /// trust only production signers. The catalog copy follows the connected
    /// bike's reported trust whenever the library has a copy that bike
    /// installs, and keeps the app's own preference otherwise.
    fileprivate static func testCatalogSelectionFollowsBikeTrust(_ corpus: Corpus) {
        let developmentBike = streamTrust(corpus.developmentAppTrust)
        let stockBike = streamTrust(corpus.productionTrust)
        let readers = readerCapabilityFixture()
        let stockFirmware = deviceStatus(trust: stockBike, mapReader: readers["production"])
        let developmentFirmware = deviceStatus(trust: developmentBike, mapReader: readers["map_pois"])

        func selection(
            _ library: OfflineMapCatalogMap,
            bike: [String]?,
            channel: String = "development"
        ) -> BikeMapStreamTrustStore {
            OfflineMapCatalogAvailabilityPolicy.selectionTrustStore(
                for: library,
                channel: channel,
                trustStore: channel == "development"
                    ? corpus.developmentAppTrust : corpus.productionTrust,
                deviceStreamTrust: bike
            )
        }
        /// Whether `variant` is the copy the app downloads and keeps without
        /// offering an update.
        func selects(
            _ variant: CorpusVariant,
            in library: OfflineMapCatalogMap,
            bike: [String]?,
            channel: String = "development"
        ) -> Bool {
            !OfflineMapCatalogAvailabilityPolicy.localArtifactNeedsRefresh(
                localArtifactSHA256s: [variant.streamArtifact["sha256"] as? String ?? ""],
                map: library,
                channel: channel,
                trustStore: selection(library, bike: bike, channel: channel)
            )
        }
        func install(
            _ map: CorpusMap,
            _ variant: CorpusVariant,
            on firmware: MapTransferDeviceStatus
        ) -> MapInstallProtocolEvaluation {
            guard let verified = try? BikeMapStreamArtifactValidator.validate(
                url: variant.url, artifact: variant.platformArtifact,
                expectedMapID: map.mapID, trustStore: corpus.developmentAppTrust
            ) else {
                corpusFailure("\(variant.file) validates in Bicino Dev")
            }
            return MapInstallProtocolSelector.evaluate(
                isBikeMapStream: true,
                signatureTrustCapability: "\(verified.signatureKeyID)=\(verified.signatureKeySHA256)",
                readerRequirements: verified.readerRequirements,
                compatibilityContract: verified.compatibilityContract,
                deviceReaderCapabilities: firmware.mapReader,
                deviceStatus: firmware
            )
        }

        for id in ["buildings-3d-v1", "topographic-contours-v1"] {
            let map = corpus.map(id)
            guard let production = map.production["production"] else {
                corpusFailure("\(id) has a production copy")
            }
            let library = catalogMap(
                map, variants: [map.development, production], deliveryState: "production"
            )
            for bike in [nil, developmentBike, stockBike] {
                assertEqual(
                    OfflineMapCatalogAvailabilityPolicy.availability(
                        for: library, channel: "development",
                        trustStore: selection(library, bike: bike)
                    ),
                    .available,
                    "\(id) availability does not depend on the connected bike"
                )
                assert(selects(production, in: library, bike: bike, channel: "production") &&
                       !selects(map.development, in: library, bike: bike, channel: "production"),
                       "Bicino keeps \(id)'s production copy whatever the bike trusts")
            }
            assertEqual(selection(library, bike: nil), corpus.developmentAppTrust,
                        "\(id) without a bike report keeps the app's signers")
            assert(selects(map.development, in: library, bike: nil) &&
                   !selects(production, in: library, bike: nil),
                   "\(id) without a bike report keeps the development copy")
            assertEqual(selection(library, bike: developmentBike), corpus.developmentAppTrust,
                        "\(id) on development firmware keeps the app's signers")
            assert(selects(map.development, in: library, bike: developmentBike) &&
                   !selects(production, in: library, bike: developmentBike),
                   "Bicino Dev keeps \(id)'s development copy for a bike that trusts it")
            assertEqual(selection(library, bike: stockBike), corpus.productionTrust,
                        "\(id) on stock firmware requests only production signers")
            assert(selects(production, in: library, bike: stockBike) &&
                   !selects(map.development, in: library, bike: stockBike),
                   "a saved development copy of \(id) is offered the production copy on stock firmware")
            assertEqual(install(map, production, on: stockFirmware), .streamV2,
                        "stock firmware installs the \(id) copy selected for it")
            assertEqual(install(map, map.development, on: stockFirmware).rejection,
                        .signingKeyNotTrusted,
                        "stock firmware refuses the \(id) development copy")
            assertEqual(install(map, map.development, on: developmentFirmware), .streamV2,
                        "development firmware installs the \(id) development copy")
        }

        // Trust is per key, not per tier: after a rotation, a bike that trusts
        // only the new production key gets that key's copy. An entry counts
        // only with the exact key fingerprint.
        let buildings = corpus.map("buildings-3d-v1")
        guard let updated = buildings.production["production-updated-worker"],
              let rotated = buildings.production["production-rotated-key"],
              let rotatedSigner = corpus.productionTrust.capability(for: "map-compat-fixture-prod-2"),
              let originalSigner = corpus.productionTrust.capability(for: "map-compat-fixture-prod-1") else {
            corpusFailure("corpus has both production keys")
        }
        let rotation = catalogMap(
            buildings, variants: [buildings.development, updated, rotated], deliveryState: "production"
        )
        assert(selects(rotated, in: rotation, bike: [rotatedSigner]) &&
               !selects(updated, in: rotation, bike: [rotatedSigner]) &&
               !selects(buildings.development, in: rotation, bike: [rotatedSigner]),
               "a bike that trusts only the rotated key gets the rotated copy")
        let forged = "map-compat-fixture-dev-1=" + String(repeating: "0", count: 64)
        assertEqual(selection(rotation, bike: [forged, originalSigner]),
                    corpus.developmentAppTrust.restricted(to: [originalSigner]),
                    "a key ID without its exact fingerprint is not bike trust")

        // With no copy the bike trusts, the app keeps its own preference: a
        // development-only map stays available to Bicino Dev, as before.
        let pois = corpus.map("map-pois-v1")
        let developmentOnly = catalogMap(pois, variants: [pois.development], deliveryState: "development")
        assertEqual(selection(developmentOnly, bike: stockBike), corpus.developmentAppTrust,
                    "with no copy the bike trusts, the app's signers decide")
        assertEqual(
            OfflineMapCatalogAvailabilityPolicy.availability(
                for: developmentOnly, channel: "development",
                trustStore: selection(developmentOnly, bike: stockBike)
            ),
            .available,
            "a development-only map stays available to Bicino Dev"
        )
        assert(selects(pois.development, in: developmentOnly, bike: stockBike),
               "the development-only copy stays current")
    }

    /// The connected bike's signers come from its authenticated map transfer
    /// status (BLE or pinned HTTPS) and are forgotten with the connection.
    @MainActor
    fileprivate static func testBikeTrustComesFromAuthenticatedStatus(_ corpus: Corpus) {
        let stockBike = streamTrust(corpus.productionTrust)
        let developmentBike = streamTrust(corpus.developmentAppTrust)
        let ble = BLEManager()
        assertEqual(ble.mapTransferStreamTrust, nil, "no bike trust before a status report")
        func notify(_ status: [String: Any]) {
            let body = try! JSONSerialization.data(withJSONObject: status)
            assert(ble.handleMapTransferStatusNotification(
                Data(DeviceBLEProtocol.mapTransferStatusPrefix.utf8) + body
            ), "BLE map transfer status is consumed")
        }
        notify(["enabled": false, "protocols": [2], "streamFormatVersions": [1],
                "streamTrust": stockBike])
        assertEqual(ble.mapTransferStreamTrust, stockBike, "BLE map status reports the bike's signers")
        notify(["enabled": false, "protocols": [Int]()])
        assertEqual(ble.mapTransferStreamTrust, nil,
                    "firmware without signed map streams reports no signers")
        ble.applyAuthenticatedMapTransferStatus(deviceStatus(trust: developmentBike, mapReader: nil))
        assertEqual(ble.mapTransferStreamTrust, developmentBike,
                    "pinned HTTPS status reports the bike's signers")
        ble.clearConnectionStateForTesting()
        assertEqual(ble.mapTransferStreamTrust, nil, "a disconnected bike's signers are forgotten")
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
        assert(!SavedMapCompatibilityPolicy.lacksDurableContract(packURL: saved),
               "Saved Maps does not mark a durable map")
    }

    fileprivate static func testMapsOutsideTheContractAreMarkedWithoutCoercion(_ corpus: Corpus) {
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
        assert(SavedMapCompatibilityPolicy.lacksDurableContract(packURL: stream),
               "a signed stream without a marker is outside the contract")
        let archive = directory.appendingPathComponent("legacy.zip")
        try! Data("PK".utf8).write(to: archive)
        assert(SavedMapCompatibilityPolicy.lacksDurableContract(packURL: archive),
               "an unsigned archive is outside the contract")
        let unreadable = directory.appendingPathComponent("damaged.bmap")
        try! Data([0x42]).write(to: unreadable)
        assert(!SavedMapCompatibilityPolicy.lacksDurableContract(packURL: unreadable),
               "a damaged file reports its own validation error")
        for map in corpus.maps {
            for variant in map.variants {
                assert(!SavedMapCompatibilityPolicy.lacksDurableContract(packURL: variant.url),
                       "\(variant.file) is not marked as outside the contract")
            }
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
